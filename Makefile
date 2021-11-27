watch:
	onfilechange graph.rb 'ruby graph.rb --only_channels 0 apu4/*.json'

push:
	scp *.html *.js *.css rafc:www/tmp/pim-lt/
