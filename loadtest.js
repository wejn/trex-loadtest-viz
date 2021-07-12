(function () {
    function LoadtestGraph(elem, profile_name) {
		var chart = c3.generate({
			bindto: elem,
			data: {
				columns: loadtest[profile_name]['data'],
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
						values: loadtest[profile_name]['ticks'],
					},
					label: {
						text: 'seconds',
						position: 'outer-center'
					}
				},
				y: {
					min: 0,
					max: loadtest[profile_name]['max'],
					padding: { top: 0, bottom: 0 },
					label: {
						text: loadtest[profile_name]['yprefix'] + 'pps',
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
						{value: loadtest[profile_name]['max']}
					]
				}
			}
		});
	}

    $(window).on("load", function() {
		$('div.loadtest-graph').each(function(index, el) {
			if (el.dataset.ltname) {
				LoadtestGraph(el, el.dataset.ltname);
			}
		});
    });

})();
