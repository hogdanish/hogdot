/**************************************************************************/
/*  library_godot_os.js                                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

const IDHandler = {
	$IDHandler: {
		_last_id: 0,
		_references: {},

		get: function (p_id) {
			return IDHandler._references[p_id];
		},

		add: function (p_data) {
			const id = ++IDHandler._last_id;
			IDHandler._references[id] = p_data;
			return id;
		},

		remove: function (p_id) {
			delete IDHandler._references[p_id];
		},
	},
};

autoAddDeps(IDHandler, '$IDHandler');
mergeInto(LibraryManager.library, IDHandler);

const GodotConfig = {
	$GodotConfig__postset: 'Module["initConfig"] = GodotConfig.init_config;',
	$GodotConfig__deps: ['$GodotRuntime'],
	$GodotConfig: {
		canvas: null,
		locale: 'en',
		canvas_resize_policy: 2, // Adaptive
		virtual_keyboard: false,
		persistent_drops: false,
		godot_pool_size: 4,
		on_execute: null,
		on_exit: null,

		init_config: function (p_opts) {
			GodotConfig.canvas_resize_policy = p_opts['canvasResizePolicy'];
			GodotConfig.canvas = p_opts['canvas'];
			GodotConfig.locale = p_opts['locale'] || GodotConfig.locale;
			GodotConfig.virtual_keyboard = p_opts['virtualKeyboard'];
			GodotConfig.persistent_drops = !!p_opts['persistentDrops'];
			GodotConfig.godot_pool_size = p_opts['godotPoolSize'];
			GodotConfig.on_execute = p_opts['onExecute'];
			GodotConfig.on_exit = p_opts['onExit'];
			if (p_opts['focusCanvas']) {
				GodotConfig.canvas.focus();
			}
		},

		locate_file: function (file) {
			return Module['locateFile'](file);
		},
		clear: function () {
			GodotConfig.canvas = null;
			GodotConfig.locale = 'en';
			GodotConfig.canvas_resize_policy = 2;
			GodotConfig.virtual_keyboard = false;
			GodotConfig.persistent_drops = false;
			GodotConfig.on_execute = null;
			GodotConfig.on_exit = null;
		},
	},

	godot_js_config_canvas_id_get__proxy: 'sync',
	godot_js_config_canvas_id_get__sig: 'vii',
	godot_js_config_canvas_id_get: function (p_ptr, p_ptr_max) {
		GodotRuntime.stringToHeap(`#${GodotConfig.canvas.id}`, p_ptr, p_ptr_max);
	},

	godot_js_config_locale_get__proxy: 'sync',
	godot_js_config_locale_get__sig: 'vii',
	godot_js_config_locale_get: function (p_ptr, p_ptr_max) {
		GodotRuntime.stringToHeap(GodotConfig.locale, p_ptr, p_ptr_max);
	},
};

autoAddDeps(GodotConfig, '$GodotConfig');
mergeInto(LibraryManager.library, GodotConfig);

const GodotFS = {
	$GodotFS__deps: ['$FS', '$IDBFS', '$GodotRuntime'],
	$GodotFS__postset: [
		'Module["initFS"] = GodotFS.init;',
		'Module["copyToFS"] = GodotFS.copy_to_fs;',
	].join(''),
	$GodotFS: {
		// ERRNO_CODES works every odd version of emscripten, but this will break too eventually.
		ENOENT: 44,
		_idbfs: false,
		_syncing: false,
		_mount_points: [],
		// navigator.storage.persist() verdict: -1 unknown/unanswered, 0 denied, 1 granted.
		// Without a granted bucket the browser may evict user:// — which now holds the
		// shader and WGSL caches — at any time, so a session must be able to say which
		// bucket it got rather than reporting a mystery slow boot.
		_persisted: -1,
		// Bound listener, kept so deinit can remove exactly what init added.
		_pagehide_cb: null,

		is_persistent: function () {
			return GodotFS._idbfs ? 1 : 0;
		},

		is_storage_persisted: function () {
			return GodotFS._persisted;
		},

		// Ask the browser to move this origin's storage out of the best-effort
		// eviction bucket. Answered asynchronously and reported through
		// _persisted, never awaited: nothing in the boot path may block on it.
		//
		// persisted() is asked FIRST so an origin that already has the grant never
		// reaches persist(). ⚠ On Firefox 155 the persist() promise NEVER SETTLED
		// against 127.0.0.1 on a fresh profile, which is the shape of a permission
		// doorhanger nobody clicked. Nothing here awaits it, so an unanswered request
		// costs a session nothing — but it is why the already-granted check comes
		// first, and why the verdict is published rather than assumed.
		request_persistence: function () {
			const storage = (typeof navigator !== 'undefined') ? navigator.storage : null;
			if (!storage || typeof storage.persist !== 'function') {
				return;
			}
			const persisted = (typeof storage.persisted === 'function')
				? storage.persisted()
				: Promise.resolve(false);
			persisted.then(function (granted) {
				if (granted) {
					GodotFS._persisted = 1;
					return null;
				}
				return storage.persist().then(function (ok) {
					GodotFS._persisted = ok ? 1 : 0;
					return null;
				});
			}).catch(function (e) {
				GodotFS._persisted = 0;
				GodotRuntime.print(`Persistent storage request failed: ${e.message}`);
			});
		},

		// Initialize godot file system, setting up persistent paths.
		// Returns a promise that resolves when the FS is ready.
		// We keep track of mount_points, so that we can properly close the IDBFS
		// since emscripten is not doing it by itself. (emscripten GH#12516).
		init: function (persistentPaths) {
			GodotFS._idbfs = false;
			if (!Array.isArray(persistentPaths)) {
				return Promise.reject(new Error('Persistent paths must be an array'));
			}
			if (!persistentPaths.length) {
				return Promise.resolve();
			}
			GodotFS._mount_points = persistentPaths.slice();

			function createRecursive(dir) {
				try {
					FS.stat(dir);
				} catch (e) {
					if (e.errno !== GodotFS.ENOENT) {
						// Let mkdirTree throw in case, we cannot trust the above check.
						GodotRuntime.error(e);
					}
					FS.mkdirTree(dir);
				}
			}

			GodotFS._mount_points.forEach(function (path) {
				createRecursive(path);
				FS.mount(IDBFS, {}, path);
			});
			GodotFS.request_persistence();
			// ⚠ pagehide, not beforeunload. beforeunload does not fire on mobile Safari
			// or on a backgrounded tab the browser discards, which are exactly the
			// sessions that lose a cache. The engine already schedules a sync on the
			// frame after any user:// write (OS_Web::main_loop_iterate), but a sync in
			// flight when the tab goes away loses that batch, and idb_is_syncing
			// suppresses a second one — so during a shader-compile wave the newest
			// writes are precisely the ones still queued.
			if (typeof window !== 'undefined' && GodotFS._pagehide_cb === null) {
				GodotFS._pagehide_cb = function () {
					GodotFS.sync(true);
				};
				window.addEventListener('pagehide', GodotFS._pagehide_cb);
			}
			return new Promise(function (resolve, reject) {
				FS.syncfs(true, function (err) {
					if (err) {
						GodotFS._mount_points = [];
						GodotFS._idbfs = false;
						GodotRuntime.print(`IndexedDB not available: ${err.message}`);
					} else {
						GodotFS._idbfs = true;
					}
					resolve(err);
				});
			});
		},

		// Deinit godot file system, making sure to unmount file systems, and close IDBFS(s).
		deinit: function () {
			GodotFS._mount_points.forEach(function (path) {
				try {
					FS.unmount(path);
				} catch (e) {
					GodotRuntime.print('Already unmounted', e);
				}
				if (GodotFS._idbfs && IDBFS.dbs[path]) {
					IDBFS.dbs[path].close();
					delete IDBFS.dbs[path];
				}
			});
			if (typeof window !== 'undefined' && GodotFS._pagehide_cb !== null) {
				window.removeEventListener('pagehide', GodotFS._pagehide_cb);
				GodotFS._pagehide_cb = null;
			}
			GodotFS._mount_points = [];
			GodotFS._idbfs = false;
			GodotFS._syncing = false;
		},

		// p_force skips the in-flight guard and does NOT touch _syncing. It exists for
		// the pagehide path only: a page that is going away cannot wait for the running
		// sync to finish and then start another, and dropping the batch is the failure
		// this is here to prevent. Two concurrent IDBFS reconciles read the same
		// in-memory tree and write the same entries, so the redundant one costs a
		// transaction, not consistency — and clearing _syncing from here would tell the
		// other sync's owner it had finished.
		sync: function (p_force) {
			if (GodotFS._syncing) {
				if (!p_force) {
					GodotRuntime.error('Already syncing!');
					return Promise.resolve();
				}
				return new Promise(function (resolve, reject) {
					FS.syncfs(false, function (error) {
						resolve(error);
					});
				});
			}
			GodotFS._syncing = true;
			return new Promise(function (resolve, reject) {
				FS.syncfs(false, function (error) {
					if (error) {
						GodotRuntime.error(`Failed to save IDB file system: ${error.message}`);
					}
					GodotFS._syncing = false;
					resolve(error);
				});
			});
		},

		// Copies a buffer to the internal file system. Creating directories recursively.
		copy_to_fs: function (path, buffer) {
			const idx = path.lastIndexOf('/');
			let dir = '/';
			if (idx > 0) {
				dir = path.slice(0, idx);
			}
			try {
				FS.stat(dir);
			} catch (e) {
				if (e.errno !== GodotFS.ENOENT) {
					// Let mkdirTree throw in case, we cannot trust the above check.
					GodotRuntime.error(e);
				}
				FS.mkdirTree(dir);
			}
			FS.writeFile(path, new Uint8Array(buffer));
		},
	},
};
mergeInto(LibraryManager.library, GodotFS);

const GodotOS = {
	$GodotOS__deps: ['$GodotRuntime', '$GodotConfig', '$GodotFS'],
	$GodotOS__postset: [
		'Module["request_quit"] = function() { GodotOS.request_quit() };',
		'Module["onExit"] = GodotOS.cleanup;',
		'GodotOS._fs_sync_promise = Promise.resolve();',
	].join(''),
	$GodotOS: {
		request_quit: function () {},
		_async_cbs: [],
		_fs_sync_promise: null,
		_browser: null,

		// The engine's ONE browser classifier. Everything that wants to know which
		// browser this is reads it here — OS.has_feature("web_safari") below, and the
		// WebGPU driver through godot_js_os_browser_id — so the two can never disagree
		// about a session.
		//
		// ⚠ Report and schedule with this; NEVER relax a correctness workaround on it.
		// A validation-driven rewrite runs for every browser, because the browser that
		// needs it is the one whose UA string the next release changes.
		//
		// `engine` is the load-bearing half: on iOS every brand is WebKit, and what
		// decides how WebGPU behaves is the implementation, not the badge. Brand order
		// matters — Chrome's UA contains "Safari", Edge's contains "Chrome".
		browser_id: function () {
			if (GodotOS._browser !== null) {
				return GodotOS._browser;
			}
			const ua = (typeof navigator !== 'undefined' && navigator.userAgent) ? navigator.userAgent : '';
			const table = [
				['FxiOS', 'firefox_ios', 'webkit'],
				['CriOS', 'chrome_ios', 'webkit'],
				['EdgiOS', 'edge_ios', 'webkit'],
				['Firefox/', 'firefox', 'gecko'],
				['Edg/', 'edge', 'blink'],
				['OPR/', 'opera', 'blink'],
				['SamsungBrowser/', 'samsung', 'blink'],
				['Chrome/', 'chrome', 'blink'],
				['Chromium/', 'chromium', 'blink'],
				['Safari/', 'safari', 'webkit'],
			];
			let name = 'other';
			let engine = 'other';
			let token = '';
			for (let i = 0; i < table.length; i++) {
				if (ua.indexOf(table[i][0]) !== -1) {
					token = table[i][0];
					name = table[i][1];
					engine = table[i][2];
					break;
				}
			}
			// Safari reports its own version as "Version/x.y", not after "Safari/".
			let version = '';
			if (engine === 'webkit' && name === 'safari') {
				token = 'Version/';
			}
			if (token !== '') {
				const at = ua.indexOf(token);
				if (at !== -1) {
					const tail = ua.slice(at + token.length);
					const m = (/^[/]?([0-9]+(?:[.][0-9]+)*)/).exec(tail);
					if (m !== null) {
						[, version] = m;
					}
				}
			}
			GodotOS._browser = { name: name, engine: engine, version: version };
			return GodotOS._browser;
		},

		atexit: function (p_promise_cb) {
			GodotOS._async_cbs.push(p_promise_cb);
		},

		cleanup: function (exit_code) {
			const cb = GodotConfig.on_exit;
			GodotFS.deinit();
			GodotConfig.clear();
			if (cb) {
				cb(exit_code);
			}
		},

		finish_async: function (callback) {
			GodotOS._fs_sync_promise.then(function (err) {
				const promises = [];
				GodotOS._async_cbs.forEach(function (cb) {
					promises.push(new Promise(cb));
				});
				return Promise.all(promises);
			}).then(function () {
				return GodotFS.sync(); // Final FS sync.
			}).then(function (err) {
				// Always deferred.
				setTimeout(function () {
					callback();
				}, 0);
			});
		},
	},

	godot_js_os_finish_async__proxy: 'sync',
	godot_js_os_finish_async__sig: 'vi',
	godot_js_os_finish_async: function (p_callback) {
		const func = GodotRuntime.get_func(p_callback);
		GodotOS.finish_async(func);
	},

	godot_js_os_request_quit_cb__proxy: 'sync',
	godot_js_os_request_quit_cb__sig: 'vi',
	godot_js_os_request_quit_cb: function (p_callback) {
		GodotOS.request_quit = GodotRuntime.get_func(p_callback);
	},

	godot_js_os_fs_is_persistent__proxy: 'sync',
	godot_js_os_fs_is_persistent__sig: 'i',
	godot_js_os_fs_is_persistent: function () {
		return GodotFS.is_persistent();
	},

	godot_js_os_fs_storage_persisted__proxy: 'sync',
	godot_js_os_fs_storage_persisted__sig: 'i',
	godot_js_os_fs_storage_persisted: function () {
		return GodotFS.is_storage_persisted();
	},

	godot_js_os_browser_id__proxy: 'sync',
	godot_js_os_browser_id__sig: 'vii',
	godot_js_os_browser_id: function (p_ptr, p_ptr_max) {
		const b = GodotOS.browser_id();
		GodotRuntime.stringToHeap(`${b.name}|${b.engine}|${b.version}`, p_ptr, p_ptr_max);
	},

	godot_js_os_fs_sync__proxy: 'sync',
	godot_js_os_fs_sync__sig: 'vi',
	godot_js_os_fs_sync: function (callback) {
		const func = GodotRuntime.get_func(callback);
		GodotOS._fs_sync_promise = GodotFS.sync();
		GodotOS._fs_sync_promise.then(function (err) {
			func();
		});
	},

	godot_js_os_has_feature__proxy: 'sync',
	godot_js_os_has_feature__sig: 'ii',
	godot_js_os_has_feature: function (p_ftr) {
		const ftr = GodotRuntime.parseString(p_ftr);
		const ua = navigator.userAgent;
		if (ftr === 'web_macos') {
			return (ua.indexOf('Mac') !== -1) ? 1 : 0;
		}
		if (ftr === 'web_windows') {
			return (ua.indexOf('Windows') !== -1) ? 1 : 0;
		}
		if (ftr === 'web_android') {
			return (ua.indexOf('Android') !== -1) ? 1 : 0;
		}
		if (ftr === 'web_ios') {
			return ((ua.indexOf('iPhone') !== -1) || (ua.indexOf('iPad') !== -1) || (ua.indexOf('iPod') !== -1)) ? 1 : 0;
		}
		if (ftr === 'web_linuxbsd') {
			return ((ua.indexOf('CrOS') !== -1) || (ua.indexOf('BSD') !== -1) || (ua.indexOf('Linux') !== -1) || (ua.indexOf('X11') !== -1)) ? 1 : 0;
		}
		// Browser identity, from the one classifier above. A project reads these to
		// ATTRIBUTE a measurement, never to change what it renders.
		if (ftr.startsWith('web_browser_')) {
			return (GodotOS.browser_id().name === ftr.slice('web_browser_'.length)) ? 1 : 0;
		}
		if (ftr.startsWith('web_engine_')) {
			return (GodotOS.browser_id().engine === ftr.slice('web_engine_'.length)) ? 1 : 0;
		}
		return 0;
	},

	godot_js_os_execute__proxy: 'sync',
	godot_js_os_execute__sig: 'ii',
	godot_js_os_execute: function (p_json) {
		const json_args = GodotRuntime.parseString(p_json);
		const args = JSON.parse(json_args);
		if (GodotConfig.on_execute) {
			GodotConfig.on_execute(args);
			return 0;
		}
		return 1;
	},

	godot_js_os_shell_open__proxy: 'sync',
	godot_js_os_shell_open__sig: 'vi',
	godot_js_os_shell_open: function (p_uri) {
		window.open(GodotRuntime.parseString(p_uri), '_blank');
	},

	godot_js_os_hw_concurrency_get__proxy: 'sync',
	godot_js_os_hw_concurrency_get__sig: 'i',
	godot_js_os_hw_concurrency_get: function () {
		// TODO Godot core needs fixing to avoid spawning too many threads (> 24).
		const concurrency = navigator.hardwareConcurrency || 1;
		return concurrency < 2 ? concurrency : 2;
	},

	godot_js_os_thread_pool_size_get__proxy: 'sync',
	godot_js_os_thread_pool_size_get__sig: 'i',
	godot_js_os_thread_pool_size_get: function () {
		if (typeof PThread === 'undefined') {
			// Threads aren't supported, so default to `1`.
			return 1;
		}

		return GodotConfig.godot_pool_size;
	},

	godot_js_os_download_buffer__proxy: 'sync',
	godot_js_os_download_buffer__sig: 'viiii',
	godot_js_os_download_buffer: function (p_ptr, p_size, p_name, p_mime) {
		const buf = GodotRuntime.heapSlice(HEAP8, p_ptr, p_size);
		const name = GodotRuntime.parseString(p_name);
		const mime = GodotRuntime.parseString(p_mime);
		const blob = new Blob([buf], { type: mime });
		const url = window.URL.createObjectURL(blob);
		const a = document.createElement('a');
		a.href = url;
		a.download = name;
		a.style.display = 'none';
		document.body.appendChild(a);
		a.click();
		a.remove();
		window.URL.revokeObjectURL(url);
	},
};

autoAddDeps(GodotOS, '$GodotOS');
mergeInto(LibraryManager.library, GodotOS);

/*
 * Godot event listeners.
 * Keeps track of registered event listeners so it can remove them on shutdown.
 */
const GodotEventListeners = {
	$GodotEventListeners__deps: ['$GodotOS'],
	$GodotEventListeners__postset: 'GodotOS.atexit(function(resolve, reject) { GodotEventListeners.clear(); resolve(); });',
	$GodotEventListeners: {
		handlers: [],

		has: function (target, event, method, capture) {
			return GodotEventListeners.handlers.findIndex(function (e) {
				return e.target === target && e.event === event && e.method === method && e.capture === capture;
			}) !== -1;
		},

		add: function (target, event, method, capture) {
			if (GodotEventListeners.has(target, event, method, capture)) {
				return;
			}
			function Handler(p_target, p_event, p_method, p_capture) {
				this.target = p_target;
				this.event = p_event;
				this.method = p_method;
				this.capture = p_capture;
			}
			GodotEventListeners.handlers.push(new Handler(target, event, method, capture));
			target.addEventListener(event, method, capture);
		},

		clear: function () {
			GodotEventListeners.handlers.forEach(function (h) {
				h.target.removeEventListener(h.event, h.method, h.capture);
			});
			GodotEventListeners.handlers.length = 0;
		},
	},
};
mergeInto(LibraryManager.library, GodotEventListeners);

const GodotPWA = {

	$GodotPWA__deps: ['$GodotRuntime', '$GodotEventListeners'],
	$GodotPWA: {
		hasUpdate: false,

		updateState: function (cb, reg) {
			if (!reg) {
				return;
			}
			if (!reg.active) {
				return;
			}
			if (reg.waiting) {
				GodotPWA.hasUpdate = true;
				cb();
			}
			GodotEventListeners.add(reg, 'updatefound', function () {
				const installing = reg.installing;
				GodotEventListeners.add(installing, 'statechange', function () {
					if (installing.state === 'installed') {
						GodotPWA.hasUpdate = true;
						cb();
					}
				});
			});
		},
	},

	godot_js_pwa_cb__proxy: 'sync',
	godot_js_pwa_cb__sig: 'vi',
	godot_js_pwa_cb: function (p_update_cb) {
		if ('serviceWorker' in navigator) {
			try {
				const cb = GodotRuntime.get_func(p_update_cb);
				navigator.serviceWorker.getRegistration().then(GodotPWA.updateState.bind(null, cb));
			} catch (e) {
				GodotRuntime.error('Failed to assign PWA callback', e);
			}
		}
	},

	godot_js_pwa_update__proxy: 'sync',
	godot_js_pwa_update__sig: 'i',
	godot_js_pwa_update: function () {
		if ('serviceWorker' in navigator && GodotPWA.hasUpdate) {
			try {
				navigator.serviceWorker.getRegistration().then(function (reg) {
					if (!reg || !reg.waiting) {
						return;
					}
					reg.waiting.postMessage('update');
				});
			} catch (e) {
				GodotRuntime.error(e);
				return 1;
			}
			return 0;
		}
		return 1;
	},
};

autoAddDeps(GodotPWA, '$GodotPWA');
mergeInto(LibraryManager.library, GodotPWA);
