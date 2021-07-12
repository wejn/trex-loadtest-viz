#!/usr/bin/env ruby

require 'json'
require 'pp'
require 'tempfile'
require 'fileutils'
require 'cgi'

KNOWN_PROFILES = Hash.new { |h, k| h[k] = File.basename(k, '.py') }
KNOWN_PROFILES['imix.py'] = 'imix'
KNOWN_PROFILES['udp_1pkt_simple_bdir.py'] = '64B'

# The point at which we consider the test failed
FAIL_THRESHOLD = 0.001

# This is akin to a global variable -- YSCALER influences the y axis scaling for the graphs
YAxisScaling = Struct.new(:divisor, :prefix)
YSCALER = YAxisScaling.new(1000000, 'M')
#YSCALER = YAxisScaling.new(1, '')

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
    STDERR.puts "W: multiple loadtest configs, expect the graphs to be garbled: #{configs.inspect}"
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
    STDERR.puts "W: multiple loadtest datapoint counts, expect the graphs to be garbled: #{configs.inspect}"
    # FTR, I expect all the loadtests to have the same amount of datapoints
end
# }}}

# Crunch the stats # {{{
Stats = Struct.new(:tx_pps, :rx_pps, :tx_util)
class Stats
    def to_s
        "%.04f,%.04f,%.04f" % [self.tx_pps, self.rx_pps, self.tx_util]
    end
end

def channel_stats(data, from, to)
    data.map do |k, v|
        tx_pps = v[from]["tx_pps"] / YSCALER.divisor.to_f
        rx_pps = v[to]["rx_pps"] / YSCALER.divisor.to_f
        Stats.new(tx_pps, rx_pps, v[from]["tx_util"])
    end
end


stats = loadtests.map do |n, l|
    if l["stats"].keys.size == 3
        STDERR.puts "W: Stats for #{n} have #{l["stats"].keys} channels (incl. global), this script can only deal with 3."
    end
    s = {}
    s[0] = channel_stats(l["stats"], "0", "1")
    s[1] = channel_stats(l["stats"], "1", "0")
    [n, s]
end.to_h

def breaking_point(data, from, to)
    bp = nil
    data.each do |k, v|
        tx_pps = v[from]["tx_pps"]
        rx_pps = v[to]["rx_pps"]
        util = v[from]["tx_util"]
        if (tx_pps - rx_pps) / tx_pps > FAIL_THRESHOLD
            if bp.nil?
                # record first fail
                bp = Stats.new(tx_pps / YSCALER.divisor.to_f, rx_pps / YSCALER.divisor.to_f, util)
            end
        else
            bp = nil # this way, when it recovers, we clear bp
        end
    end
    bp
end

breaking_points = loadtests.map do |n, l|
    if l["stats"].keys.size == 3
        STDERR.puts "W: Stats for #{n} have #{l["stats"].keys} channels (incl. global), this script can only deal with 3."
    end
    s = {}
    s[0] = breaking_point(l["stats"], "0", "1")
    s[1] = breaking_point(l["stats"], "1", "0")
    [n, s]
end.to_h

# }}}

# Dump the data to tempfile # {{{
files = stats.map do |n, s|
    f = Tempfile.new("loadtest-stats-#{n}")
    s[0].each_with_index { |stat, i| f.puts("#{i}," + stat.to_s + "," + s[1][i].to_s) }
    f.fsync rescue nil
    [n, f]
end.to_h
# }}}

# Compute per profile json (for the graphs)
ltdata = {}
profiles = loadtests.map { |_, c| c['vars']['profile_file'] }.sort.uniq
profiles.each do |profile|
    pn = KNOWN_PROFILES[profile]
    out = {}
    l = loadtests.find_all { |n, l| l['vars']['profile_file'] == profile }.to_h
    max = l.map { |n, _| stats[n].map { |k, v| v.map { |x| x.tx_pps }.max }.max }.max
    ideal = []
    l.each { |n, _| stats[n].each { |k, v| v.each_with_index { |x, i| ideal[i] ||= 0.0; ideal[i] = [ideal[i], x.tx_pps].max } } }
    ticks = 0.step(ideal.size - (ideal.size % 100), 100).to_a
    out['max'] = max
    out['yprefix'] = YSCALER.prefix
    out['ticks'] = ticks
    out['data'] = [
        ['ideal'] + ideal.map { |x| x.round(3) },
    ]
    l.each do |tn, _|
        stats[tn].each do |ch, data|
            out['data'] << (["#{tn} #{ch}→#{1-ch} rx"] + data.map { |x| x.rx_pps.round(3) })
        end
    end
    ltdata[pn] = out
end

# Output
## Html
t = Tempfile.new('index-html')
begin
    t.puts <<-'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <link href="c3.css" rel="stylesheet">
    <script src="d3.v5.min.js" charset="utf-8"></script>
    <script src="c3.min.js"></script>
    <script src="jquery.min.js"></script>
    <script src="loadtest.js"></script>
    <style>
      .loadtest-graph { margin: 2em 0; }
      table { border: 2px solid black; border-collapse: collapse; }
      table th { border: 1px solid #aaa; padding: 0.2em 0.5em; }
      table th:not([colspan]) { border-bottom: 2px solid black; }
      table td { border: 1px solid #aaa; padding: 0.2em 0.5em; }
    </style>
    <title>Loadtest results</title>
  </head>
  <body>
    <h1>Loadtest results</h1>
    EOF
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
        <td>#{k}</td>
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
        t.puts "    <caption>Point of overload</caption>"
        t.puts "    <tr>"
        t.puts "      <th rowspan=\"2\">Profile</th>"
        t.puts "      <th colspan=\"2\">Channel 0</th>"
        t.puts "      <th colspan=\"2\">Channel 1</th>"
        t.puts "    </tr>"
        t.puts "    <tr>"
        t.puts "      <th>#{YSCALER.prefix}pps</th>"
        t.puts "      <th>%LR</th>"
        t.puts "      <th>#{YSCALER.prefix}pps</th>"
        t.puts "      <th>%LR</th>"
        t.puts "    </tr>"
        bpsort = lambda { |(ln, _)| bp = breaking_points[ln]; [bp[0] ? -bp[0].tx_util : -101, bp[1] ? -bp[1].tx_util : -101] }
        l.sort_by(&bpsort).each do |ln, _|
            bp = breaking_points[ln]
            t.puts "    <tr>"
            t.puts "      <td>#{ln}</td>"
            t.puts "      <td>#{bp[0].nil? ? 'N/A' : bp[0].rx_pps.round(3)}</td>"
            t.puts "      <td>#{bp[0].nil? ? 'N/A' : ('%.02f%%' % bp[0].tx_util)}</td>"
            t.puts "      <td>#{bp[1].nil? ? 'N/A' : bp[1].rx_pps.round(3)}</td>"
            t.puts "      <td>#{bp[1].nil? ? 'N/A' : ('%.02f%%' % bp[1].tx_util)}</td>"
            t.puts "    </tr>"
        end
        t.puts "    </table>"
        t.puts "    <div class=\"loadtest-graph\" data-ltdata=\"#{CGI.escapeHTML(ltdata[pn].to_json)}\" style=\"width: 1200px; height: 600px\"></div>"
    end
    t.puts <<-'EOF'
  </body>
</html>
    EOF
    t.close
    FileUtils.cp(t.path, 'index.html')
    File.chmod((0666 ^ File.umask), 'index.html')
ensure
    t.close
    t.unlink
end


# Cleanup
files.each { |n, f| f.close; f.unlink }
