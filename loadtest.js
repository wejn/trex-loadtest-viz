(function () {
    function LoadtestGraph(elem, ltdata) {
		var chart = c3.generate({
			bindto: elem,
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
					label: {
						text: ltdata['yprefix'] + 'pps',
						position: 'outer-middle'
					}
				},
				y2: {
					show: true,
					min: 0,
					max: 100,
					padding: { top: 0, bottom: 0 },
					label: {
						text: '% of linerate',
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

    $(window).on("load", function() {
		$('div.loadtest-graph').each(function(index, el) {
			if (el.dataset.ltdata) {
				LoadtestGraph(el, JSON.parse(el.dataset.ltdata));
			}
		});
    });

})();
