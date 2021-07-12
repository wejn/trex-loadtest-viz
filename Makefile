watch:
	onfilechange graph.rb 'ruby graph.rb apu4/*.json'

push:
	scp *.html *.js *.css rafc:www/tmp/pim-lt/
