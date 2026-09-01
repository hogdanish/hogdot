/* hogdot perf bed — page-side instruments. Injected by export.sh into html/head_include, so it
   runs before the engine loads. Single quotes only (the preset stores it in a double-quoted
   string); no line comments (lines are joined with spaces). Exposes window.__bench:
     rafCount()      number of requestAnimationFrame callbacks so far
     rafTail(n)      JSON [[t, busy_ms], …] for the last n callbacks (busy = time inside the callback)
     longTasks(t)    JSON [count, total_ms, max_ms] of long tasks since performance.now() t
     apiTail(n)      JSON [[…16 counters], …] WebGPU API calls issued during each of the last n
                     callbacks; see API_KEYS for the column order. Works on any build, including
                     GodotWebGPU 4.6.2, because it wraps the browser's own GPU* prototypes.
     now()           performance.now() */
(function () {
	var g = window;
	var N = 16;
	var b = { raf: [], cap: 8192, lt: [], api: [], c: new Float64Array(N), byLabel: {} };
	function account(kind, label, bytes) {
		var k = kind + ':' + (label || '(unlabeled)');
		var e = b.byLabel[k];
		if (!e) { e = b.byLabel[k] = [0, 0, 0]; }
		e[0] += 1; e[1] += bytes; if (bytes > e[2]) { e[2] = bytes; }
	}
	b.API_KEYS = ['wb', 'wb_bytes', 'wt', 'wt_bytes', 'submit', 'encoders', 'rp', 'cp', 'draw', 'setbg', 'setpipe', 'setvb', 'setib', 'dispatch', 'create_bg', 'create_buf'];
	function wrap(proto, name, idx, bytesFn) {
		if (!proto || !proto[name]) { return; }
		var o = proto[name];
		proto[name] = function () {
			b.c[idx] += 1;
			if (bytesFn) { b.c[idx + 1] += bytesFn(arguments); }
			return o.apply(this, arguments);
		};
	}
	var noapi = location.search.indexOf('noapi') >= 0;
	if (noapi) { g.GPUQueue = null; g.GPUDevice = null; g.GPUCommandEncoder = null; g.GPURenderPassEncoder = null; g.GPUComputePassEncoder = null; }
	if (g.GPUQueue) {
		wrap(GPUQueue.prototype, 'writeBuffer', 0, function (a) { var n = a[4] !== undefined ? a[4] : (a[2].byteLength - (a[3] || 0)); account('wb', a[0] && a[0].label, n); return n; });
		wrap(GPUQueue.prototype, 'writeTexture', 2, function (a) { var n = a[1].byteLength; account('wt', a[0] && a[0].texture && a[0].texture.label, n); return n; });
		wrap(GPUQueue.prototype, 'submit', 4);
	}
	if (g.GPUDevice) {
		wrap(GPUDevice.prototype, 'createCommandEncoder', 5);
		wrap(GPUDevice.prototype, 'createBindGroup', 14);
		wrap(GPUDevice.prototype, 'createBuffer', 15);
	}
	if (g.GPUCommandEncoder) {
		wrap(GPUCommandEncoder.prototype, 'beginRenderPass', 6);
		wrap(GPUCommandEncoder.prototype, 'beginComputePass', 7);
	}
	if (g.GPURenderPassEncoder) {
		wrap(GPURenderPassEncoder.prototype, 'draw', 8);
		wrap(GPURenderPassEncoder.prototype, 'drawIndexed', 8);
		wrap(GPURenderPassEncoder.prototype, 'setBindGroup', 9);
		wrap(GPURenderPassEncoder.prototype, 'setPipeline', 10);
		wrap(GPURenderPassEncoder.prototype, 'setVertexBuffer', 11);
		wrap(GPURenderPassEncoder.prototype, 'setIndexBuffer', 12);
	}
	if (g.GPUComputePassEncoder) {
		wrap(GPUComputePassEncoder.prototype, 'dispatchWorkgroups', 13);
		wrap(GPUComputePassEncoder.prototype, 'setBindGroup', 9);
	}
	var o = g.requestAnimationFrame.bind(g);
	g.requestAnimationFrame = function (cb) {
		return o(function (ts) {
			var t0 = performance.now();
			try {
				return cb(ts);
			} finally {
				var d = performance.now() - t0;
				b.raf.push(t0, d);
				b.api.push(Array.prototype.slice.call(b.c));
				b.c.fill(0);
				if (b.raf.length > b.cap * 2) {
					b.raf.splice(0, b.raf.length - b.cap * 2);
					b.api.splice(0, b.api.length - b.cap);
				}
			}
		});
	};
	try {
		new PerformanceObserver(function (l) {
			var e = l.getEntries();
			for (var i = 0; i < e.length; i++) { b.lt.push(e[i].startTime, e[i].duration); }
		}).observe({ type: 'longtask', buffered: true });
	} catch (e) { }
	b.rafCount = function () { return b.raf.length / 2; };
	b.rafTail = function (n) {
		var a = b.raf, m = Math.min(n, a.length / 2), out = [];
		for (var i = a.length - 2 * m; i < a.length; i += 2) { out.push([a[i], a[i + 1]]); }
		return JSON.stringify(out);
	};
	b.apiTail = function (n) {
		var m = Math.min(n, b.api.length);
		return JSON.stringify(b.api.slice(b.api.length - m));
	};
	b.longTasks = function (t) {
		var c = 0, mx = 0, s = 0;
		for (var i = 0; i < b.lt.length; i += 2) {
			if (b.lt[i] >= t) { c++; s += b.lt[i + 1]; if (b.lt[i + 1] > mx) { mx = b.lt[i + 1]; } }
		}
		return JSON.stringify([c, s, mx]);
	};
	b.byLabelTop = function (n) {
		var rows = Object.keys(b.byLabel).map(function (k) { return [k, b.byLabel[k][0], b.byLabel[k][1], b.byLabel[k][2]]; });
		rows.sort(function (x, y) { return y[2] - x[2]; });
		return rows.slice(0, n);
	};
	b.now = function () { return performance.now(); };
	g.__bench = b;
})();
