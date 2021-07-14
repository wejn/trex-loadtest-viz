(function () {
    function Graph(elem, ltdata, error) {
	var chart = c3.generate({
		bindto: elem,
		size: {
		    width: 1200,
		    height: error ? 300 : 600,
		},
		data: {
			columns: ltdata['data'],
			regions: {
				'ideal': [{'start': 0, 'style': 'dashed'}]
			},
			colors: {
				'ideal': '#bbbbbb',
			}
		},
		point: {
			show: false
		},
		axis: {
			x: {
				tick: {
					values: ltdata['ticks'],
				},
				label: {
					text: 'seconds',
					position: 'outer-center'
				}
			},
			y: {
				min: 0,
				max: ltdata['max'],
				padding: { top: 0, bottom: 0 },
				type: (error ? 'log' : 'linear'),
				tick: {
				    format: d3.format('.3f'),
				},
				label: {
				    text: (error ? 'error ' : '') + ltdata['yprefix'] + 'pps' + (error ? " (log)" : ""),
				    position: 'outer-middle'
				}
			},
			y2: {
				show: true,
				min: 0,
				max: 1,
				type: (error ? 'log' : 'linear'),
				tick: {
				    format: d3.format(error ? '.3f' : '.1f'),
				},
				padding: { top: 0, bottom: 0 },
				label: {
					text: 'fraction of linerate',
					position: 'outer-middle'
				}
			}
		},
		grid: {
			y: {
				lines: [
					{value: ltdata['max']}
				]
			}
		}
	});
    }

    function LoadtestGraph(elem, ltdata) {
	return Graph(elem, ltdata, false);
    }

    function ErrorGraph(elem, ltdata) {
	return Graph(elem, ltdata, true);
    }

    $(window).on("load", function() {
		$('div.loadtest-graph').each(function(index, el) {
			if (el.dataset.ltdata) {
				LoadtestGraph(el, JSON.parse(el.dataset.ltdata));
			} else if (el.dataset.errdata) {
				ErrorGraph(el, JSON.parse(el.dataset.errdata));
			}
		});
    });

})();
