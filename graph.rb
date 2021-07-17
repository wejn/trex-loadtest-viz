#!/usr/bin/env ruby

require 'cgi'
require 'fileutils'
require 'json'
require 'optparse'
require 'tempfile'

KNOWN_PROFILES = Hash.new { |h, k| h[k] = File.basename(k, '.py') }
KNOWN_PROFILES['imix.py'] = 'imix'
KNOWN_PROFILES['udp_1pkt_simple_bdir.py'] = '64B'

YAxisScaling = Struct.new(:divisor, :prefix)
class YAxisScaling
  def to_s
    "#{self.divisor}:#{self.prefix}"
  end
end

FAIL_THRESHOLD_RANGE=(0.0001..1.0)

OPTIONS = {
  # Output file
  output: 'index.html',

  # The point at which we consider the test failed
  fail_threshold: 0.001,

  # The Y axis scaler
  yscaler: YAxisScaling.new(1000_000, 'M'),

  # url prefix for assets (js, css) in the HTML output
  asset_prefix: ''
}

WARNINGS = []

def warn(msg)
  WARNINGS << msg
  STDERR.puts "W: #{msg}"
end

# Parse options / input
opts = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename($0)} [options] <loadtest.json>+"
  opts.separator 'Available options:'

  opts.on('-o', '--output FILE', String,
          "File into which write the output, default: #{OPTIONS[:output]}") do |of|
    OPTIONS[:output] = of
  end

  opts.on('-f', '--fail-threshold THRESHOLD', Float,
          "Float fraction of loss (#{FAIL_THRESHOLD_RANGE.to_s}) at which the test is considered failed, default: #{OPTIONS[:fail_threshold]}") do |ft|
    raise OptionParser::InvalidArgument, "must be in (#{FAIL_THRESHOLD_RANGE}) range" unless FAIL_THRESHOLD_RANGE.include?(ft)

    OPTIONS[:fail_threshold] = ft
  end

  opts.on('-y', '--yscaler DIVISOR:PREFIX', String,
          "Y axis scaler (divisor:prefix), divisor is an integer > 0, default: #{OPTIONS[:yscaler]}") do |ys|
    rexp = /\A(\d+):(\w*)\z/m
    begin
      if rexp =~ ys
        n = Integer($1)
        raise "wrong n" if n <= 0
        OPTIONS[:yscaler] = YAxisScaling.new(n, $2)
      else
        raise "didn't match the regexp"
      end
    rescue Object
      raise OptionParser::InvalidArgument, "must be formatted as: #{rexp} and num must be > 0"
    end
  end

  opts.on('-a', '--asset-prefix PREFIX', String,
          "HTML assets (js, css) prefix, default: '#{OPTIONS[:asset_prefix]}'") do |ap|
    OPTIONS[:asset_prefix] = ap
  end

  opts.on_tail('-h', '--help', 'Show this message') do
    STDERR.puts opts
    exit 1
  end
end

begin
  opts.parse!(ARGV)
rescue OptionParser::InvalidOption
  STDERR.puts "E: invalid option: #{$!}"
  exit 1
rescue OptionParser::InvalidArgument
  STDERR.puts "E: invalid argument: #{$!.args.join(' ')}"
  exit 1
end



# Load up the loadtests # {{{
all_inputs_ok = true
loadtests = ARGV.map do |c|
    fn = File.basename(c, '.json')
    data = nil
    begin
        data = JSON.parse(File.read(c))
    rescue Object
        STDERR.puts "E: Input '#{c}' can't be parsed as json: #{$!.to_s.gsub(/\n.*/m, '')}"
        all_inputs_ok = false
    end
    if data
        unless (data.keys & ["vars", "stats"]).size == 2
            STDERR.puts "E: Input '#{c}' doesn't look like a loadtest (is missing some top level keys)."
            all_inputs_ok = false
        end
    end
    [fn, data]
end.to_h
unless all_inputs_ok
    STDERR.puts "F: Error while reading loadtest files, abort."
    exit 1
end
# }}}

# Sanity checks # {{{
config_keys_to_verify = %w[warmup_mult warmup_duration rampup_target rampup_duration hold_duration]
configs = loadtests.map { |_, t| t["vars"].fetch_values(*config_keys_to_verify) }.sort.uniq
case configs.size
when 0
    STDERR.puts "F: Looks like empty set of configs, abort."
    exit 1
when 1
    # good, expect all loadtests to have same config
else
    warn "multiple loadtest configs, expect the graphs to be garbled: #{configs.inspect}"
    # FTR, I expect all the keys from config_keys_to_verify to be the same value
end

datapoints = loadtests.map { |_, t| t["stats"].keys.size }.sort.uniq
case datapoints.size
when 0
    STDERR.puts "F: Looks like empty set of datapoints, abort."
    exit 1
when 1
    if datapoints.first.zero?
        STDERR.puts "F: Looks like the num of datapoints is zero, abort."
        exit 1
    else
        # good, I expect all datapoints of same size, and non-zero at that
    end
else
    warn "multiple loadtest datapoint counts, expect the graphs to be garbled: #{datapoints.inspect}"
    # FTR, I expect all the loadtests to have the same amount of datapoints
end
# }}}

# Crunch the stats # {{{
Stats = Struct.new(:tx_pps, :rx_pps, :tx_util, :rx_loss)

def channel_stats(data, from, to)
    data.map do |k, v|
        tx_pps = v[from]["tx_pps"] / OPTIONS[:yscaler].divisor.to_f
        rx_pps = v[to]["rx_pps"] / OPTIONS[:yscaler].divisor.to_f
        rx_loss = (v[from]['tx_pps'] - v[to]['rx_pps']) / v[from]['tx_pps']
        rx_loss = 0.0 if rx_loss < 0.0
        Stats.new(tx_pps, rx_pps, v[from]["tx_util"], rx_loss)
    end
end


stats = loadtests.map do |n, l|
    if l["stats"].keys.size == 3
        warn "Stats for #{n} have #{l["stats"].keys} channels (incl. global), this script can only deal with 3."
    end
    s = {}
    s[0] = channel_stats(l["stats"], "0", "1")
    s[1] = channel_stats(l["stats"], "1", "0")
    [n, s]
end.to_h

# max_ok_pps - pps where loss <= OPTIONS[:fail_threshold]
# max_pps - absolute max pps value
# max_lr_perc - absolute max percentage of linerate achieved
MaxPerf = Struct.new(:max_ok_pps, :max_pps, :max_lr_perc)

def eval_max_performance(data, from, to)
    max_lr_perc = 0
    max_pps = 0
    max_ok_pps = nil
    data.each do |k, v|
        tx_pps = v[from]["tx_pps"]
        rx_pps = v[to]["rx_pps"]
        util = v[to]["rx_util"]
        if (tx_pps - rx_pps) / tx_pps > OPTIONS[:fail_threshold]
            if max_ok_pps.nil?
                # record first fail
                max_ok_pps = rx_pps
            end
        else
            max_ok_pps = nil # this way, when it recovers, we clear max_ok_pps
        end
        max_lr_perc = max_lr_perc < util ? util : max_lr_perc
        max_pps = max_pps < rx_pps ? rx_pps : max_pps
    end
    max_ok_pps = max_pps if max_ok_pps.nil?
    max_lr_perc = 100.0 if max_lr_perc > 100.0
    MaxPerf.new(max_ok_pps / OPTIONS[:yscaler].divisor.to_f, max_pps / OPTIONS[:yscaler].divisor.to_f, max_lr_perc)
end

max_performance = loadtests.map do |n, l|
    if l["stats"].keys.size == 3
        warn "Stats for #{n} have #{l["stats"].keys} channels (incl. global), this script can only deal with 3."
    end
    s = {}
    s[0] = eval_max_performance(l["stats"], "0", "1")
    s[1] = eval_max_performance(l["stats"], "1", "0")
    [n, s]
end.to_h

# }}}

# Compute per profile json (for the graphs)
ltdata = {}
edata = {}
profiles = loadtests.map { |_, c| c['vars']['profile_file'] }.sort.uniq
profiles.each do |profile|
    pn = KNOWN_PROFILES[profile]
    out = {} # out common
    od = [] # out data
    oe = [] # out errors
    l = loadtests.find_all { |n, l| l['vars']['profile_file'] == profile }.to_h
    max = l.map { |n, _| stats[n].map { |k, v| v.map { |x| x.tx_pps }.max }.max }.max
    ideal = []
    l.each { |n, _| stats[n].each { |k, v| v.each_with_index { |x, i| ideal[i] ||= 0.0; ideal[i] = [ideal[i], x.tx_pps].max } } }
    maxdp = datapoints.first + 1
    ticks = 0.step(maxdp - (maxdp % 100), 100).to_a
    out['max'] = max
    out['yprefix'] = OPTIONS[:yscaler].prefix
    out['ticks'] = ticks
    od << (['ideal'] + ideal.map { |x| x.round(3) })
    oe << (['txrate'] + ideal.map { |x| x.round(3) })
    l.each do |tn, _|
        stats[tn].each do |ch, data|
            od << (["#{tn} #{ch}→#{1-ch} rx"] + data.map { |x| x.rx_pps.round(3) })
            oe << (["#{tn} #{ch}→#{1-ch} err"] + data.map { |x| x.rx_loss.round(3) })
        end
    end
    ltdata[pn] = out.dup.merge({'data': od})
    edata[pn] = out.dup.merge({'data': oe, 'ft': OPTIONS[:fail_threshold]})
end

# Output
## Html
def ap(f)
  pfx = OPTIONS[:asset_prefix]
  # empty prefix -> just asset
  if [nil, ''].include?(pfx)
    f
  else
    # trailing '/' vs without
    pfx[-1,1] == '/' ? pfx + f : [pfx, f].join('/')
  end
end

t = Tempfile.new('index-html')
begin
    t.puts <<-EOF
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <link href="#{ap('c3.css')}" rel="stylesheet">
    <script src="#{ap('d3.v5.min.js')}" charset="utf-8"></script>
    <script src="#{ap('c3.min.js')}"></script>
    <script src="#{ap('jquery.min.js')}"></script>
    <script src="#{ap('loadtest.js')}"></script>
    <style>
      .loadtest-graph { margin: 2em 0; }
      .ft line { stroke: #a00; fill: #a00; }
      .ft text { stroke: #a00 }
      table { border: 2px solid black; border-collapse: collapse; }
      table th { border: 1px solid #aaa; padding: 0.2em 0.5em; }
      table th:not([colspan]) { border-bottom: 2px solid black; }
      table td { text-align: right; border: 1px solid #aaa; padding: 0.2em 0.5em; }
      table td.left { text-align: left; }
    </style>
    <title>Loadtest results</title>
  </head>
  <body>
    <h1>Loadtest results</h1>
    EOF
    # Warnings section
    unless WARNINGS.empty?
      t.puts "    <h2>Generator warnings</h2>"
      t.puts "    <ul>"
      for w in WARNINGS
        t.puts "      <li>#{CGI.escapeHTML(w)}</li>"
      end
      t.puts "    </ul>"
    end
    # Config section
    t.puts <<-'EOF'
    <h2>Config</h2>
    <table class="config-table">
      <tr>
        <th>key</th>
        <th>value</th>
      </tr>
    EOF
    config_keys_to_verify.zip(configs.first).each do |k,v|
        t.puts <<-EOF
      <tr>
        <td class="left">#{k}</td>
        <td>#{v}</td>
      </tr>
        EOF
    end
    t.puts "    </table>"
    # Per-profile sections
    profiles.each do |profile|
        pn = KNOWN_PROFILES[profile]
        l = loadtests.find_all { |n, l| l['vars']['profile_file'] == profile }.to_h
        t.puts "    <h2>Profile: #{pn}</h2>"
        t.puts "    <table class=\"stats-table\">"
        t.puts "    <caption>Performance max</caption>"
        t.puts "    <tr>"
        t.puts "      <th rowspan=\"2\">Test name</th>"
        t.puts "      <th colspan=\"3\">Channel 0→1</th>"
        t.puts "      <th colspan=\"3\">Channel 1→0</th>"
        t.puts "    </tr>"
        t.puts "    <tr>"
        t.puts "      <th>#{OPTIONS[:yscaler].prefix}pps at &lt;#{"%.2f" % [OPTIONS[:fail_threshold]*100]}% loss</th>"
        t.puts "      <th>#{OPTIONS[:yscaler].prefix}pps</th>"
        t.puts "      <th>%LR</th>"
        t.puts "      <th>#{OPTIONS[:yscaler].prefix}pps at &lt;#{"%.2f" % [OPTIONS[:fail_threshold]*100]}% loss</th>"
        t.puts "      <th>#{OPTIONS[:yscaler].prefix}pps</th>"
        t.puts "      <th>%LR</th>"
        t.puts "    </tr>"
        mpsort = lambda { |(ln, _)| mp = max_performance[ln]; [-mp[0].max_lr_perc, -mp[1].max_lr_perc] }
        l.sort_by(&mpsort).each do |ln, _|
            mp = max_performance[ln]
            t.puts "    <tr>"
            t.puts "      <td class=\"left\">#{ln}</td>"
            t.puts "      <td>#{'%.03f' % mp[0].max_ok_pps}</td>"
            t.puts "      <td>#{'%.03f' % mp[0].max_pps}</td>"
            t.puts "      <td>#{'%.02f%%' % mp[0].max_lr_perc}</td>"
            t.puts "      <td>#{'%.03f' % mp[1].max_ok_pps}</td>"
            t.puts "      <td>#{'%.03f' % mp[1].max_pps}</td>"
            t.puts "      <td>#{'%.02f%%' % mp[1].max_lr_perc}</td>"
            t.puts "    </tr>"
        end
        t.puts "    </table>"
        t.puts "    <div class=\"loadtest-graph\" data-ltdata=\"#{CGI.escapeHTML(ltdata[pn].to_json)}\"></div>"
        t.puts "    <details><summary>Error graph (click to show)</summary>"
        t.puts "    <div class=\"loadtest-graph\" data-errdata=\"#{CGI.escapeHTML(edata[pn].to_json)}\"></div>"
        t.puts "    </details>"
    end
    t.puts <<-'EOF'
  </body>
</html>
    EOF
    t.close
    if OPTIONS[:output] == '-' || OPTIONS[:output].empty?
      STDOUT.puts File.read(t.path)
    else
      File.open(OPTIONS[:output], 'w') { |f| f.write(File.read(t.path)) }
    end
ensure
    t.close
    t.unlink
end
