#!/usr/bin/env ruby

require 'json'
require 'pp'
require 'tempfile'
require 'fileutils'

KNOWN_PROFILES = Hash.new { |h, k| h[k] = File.basename(k, '.py') }
KNOWN_PROFILES['imix.py'] = 'imix'
KNOWN_PROFILES['udp_1pkt_simple_bdir.py'] = '64B'

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
Stats = Struct.new(:loss, :tx_pps, :rx_pps, :util)
class Stats
	def to_s
		"%.04f,%.04f,%.04f,%.04f" % [self.loss, self.tx_pps, self.rx_pps, self.util]
	end
end

def channel_stats(data, from, to)
	data.map do |k, v|
		tx_pps = v[from]["tx_pps"]
		rx_pps = v[to]["rx_pps"]
		loss = tx_pps - rx_pps
		Stats.new(loss, tx_pps, rx_pps, v[from]["tx_util"])
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

# }}}

# Dump the data to tempfile # {{{
files = stats.map do |n, s|
	f = Tempfile.new("loadtest-stats-#{n}")
	s[0].each_with_index { |stat, i| f.puts("#{i}," + stat.to_s + "," + s[1][i].to_s) }
	f.fsync rescue nil
	[n, f]
end.to_h
# }}}

# Output
def do_single_graph(name, data_file, max_tx_pps = nil)
	# XXX: the y2 axis assumes that when max_tx_pps hits maximum, it equals 100% line util
	IO.popen('gnuplot', 'w') do |f|
		f.puts <<-EOF
		set terminal png size 1200,800
		set datafile separator ","
		set output "#{name}.png"
		set ylabel "pps"
		set ytics nomirror
		set yrange [0<*:#{max_tx_pps}]
		set y2label "line util%"
		set y2range [0:100]
		set y2tics 10
		set key left top
		set multiplot layout 2,1
		set title "#{name} - Channel 0"
		plot "#{data_file}" using 1:2 title "loss pps" with lines lt rgb "#ff0000" axes x1y1, \
			"#{data_file}" using 1:3 title "tx pps" with lines lt rgb "#cccc00" axes x1y1, \
			"#{data_file}" using 1:4 title "rx pps" with lines lt rgb "#00cc00" axes x1y1
		set title "#{name} - Channel 1"
		plot "#{data_file}" using 1:6 title "loss pps" with lines lt rgb "#ff0000" axes x1y1, \
			"#{data_file}" using 1:7 title "tx pps" with lines lt rgb "#cccc00" axes x1y1, \
			"#{data_file}" using 1:8 title "rx pps" with lines lt rgb "#00cc00" axes x1y1
		quit
		EOF
	end
	$?.exitstatus
end

def do_multi_graph(name, loadtests, files, max_tx_pps = nil)
	# XXX: the y2 axis assumes that when max_tx_pps hits maximum, it equals 100% line util
	# XXX: further assumption -- the TXes are ~same -> using one color and "tx" as name
	plots_0 = []
	plots_0_loss = []
	plots_1 = []
	plots_1_loss = []
	loadtests.each do |n, l|
		plots_0 << "\"#{files[n].path}\" using 1:3 title \"tx\" with lines axes x1y1" if plots_0.empty?
		plots_0 << "\"#{files[n].path}\" using 1:4 title \"#{n} rx\" with lines axes x1y1"
		plots_0_loss << "\"#{files[n].path}\" using 1:3 title \"tx\" with lines axes x1y1" if plots_0_loss.empty?
		plots_0_loss << "\"#{files[n].path}\" using 1:2 title \"#{n} loss\" with lines axes x1y1"
		plots_1 << "\"#{files[n].path}\" using 1:7 title \"tx\" with lines axes x1y1" if plots_1.empty?
		plots_1 << "\"#{files[n].path}\" using 1:8 title \"#{n} rx\" with lines axes x1y1"
		plots_1_loss << "\"#{files[n].path}\" using 1:7 title \"tx\" with lines axes x1y1" if plots_1_loss.empty?
		plots_1_loss << "\"#{files[n].path}\" using 1:6 title \"#{n} loss\" with lines axes x1y1"

	end
	IO.popen('gnuplot', 'w') do |f|
		f.puts <<-EOF
		set terminal png size 1200,1200
		set datafile separator ","
		set output "#{name}.png"
		set ylabel "pps"
		set ytics nomirror
		set yrange [0<*:#{max_tx_pps}]
		set y2label "line util%"
		set y2range [0:100]
		set y2tics 10
		set key left top
		set multiplot layout 4,1
		set title "#{name} - Channel 0 rx"
		plot #{plots_0.join(", ")}
		set title "#{name} - Channel 0 loss"
		plot #{plots_0_loss.join(", ")}
		set title "#{name} - Channel 1 rx"
		plot #{plots_1.join(", ")}
		set title "#{name} - Channel 1 loss"
		plot #{plots_1_loss.join(", ")}
		quit
		EOF
	end
	$?.exitstatus
end

## Single graphs
files.each do |n, f|
	max = stats[n].map { |k, v| v.map { |x| x.tx_pps }.max }.max
	ret = do_single_graph(n, f.path, max)
	#FileUtils.cp(f.path, "#{n}.dta") if $DEBUG && ret != 0
end

## Per profile graphs
profiles = loadtests.map { |_, c| c['vars']['profile_file'] }.sort.uniq

profiles.each do |profile|
	pn = KNOWN_PROFILES[profile]
	l = loadtests.find_all { |n, l| l['vars']['profile_file'] == profile }.to_h
	max = l.map { |n, _| stats[n].map { |k, v| v.map { |x| x.tx_pps }.max }.max }.max
	do_multi_graph(pn, l, files, max)
end

# Cleanup
files.each { |n, f| f.close; f.unlink }
