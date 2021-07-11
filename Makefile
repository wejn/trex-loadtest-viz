watch:
	onfilechange graph.rb 'ruby graph.rb apu4/*.json'

push:
	rm -f graph.rb.html
	beautify graph.rb
	scp *.png *.html graph.rb *.js *.css rafc:www/tmp/pim-lt/
