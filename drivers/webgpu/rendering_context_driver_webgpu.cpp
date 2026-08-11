/**************************************************************************/
/*  rendering_context_driver_webgpu.cpp                                   */
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

#ifdef WEBGPU_ENABLED

#include "rendering_context_driver_webgpu.h"

#include "drivers/webgpu/rendering_device_driver_webgpu.h"

// html5_webgpu.h was removed in Emscripten 5.x when USE_WEBGPU was dropped.
// Device is now created from C++ using the emdawnwebgpu port's Dawn API.
#include <emscripten/emscripten.h>

// ⚠ Emscripten does not scan EM_ASM bodies for JS library symbols, so a runtime helper
// used only from one gets dead-stripped and fails at run time, not at link time. The
// adapter-identity block below calls stringToNewUTF8; declare that dependency explicitly.
EM_JS_DEPS(godot_webgpu_context_deps, "$stringToNewUTF8");

RenderingContextDriverWebGPU::RenderingContextDriverWebGPU() {
}

RenderingContextDriverWebGPU::~RenderingContextDriverWebGPU() {
	if (queue) {
		wgpuQueueRelease(queue);
		queue = nullptr;
	}
	if (device) {
		wgpuDeviceRelease(device);
		device = nullptr;
	}
	if (adapter) {
		wgpuAdapterRelease(adapter);
		adapter = nullptr;
	}
	if (instance) {
		wgpuInstanceRelease(instance);
		instance = nullptr;
	}
}

Error RenderingContextDriverWebGPU::initialize() {
	// The HTML shell pre-initializes a GPUDevice and stores it in Module.preinitializedWebGPUDevice.
	// We use the emdawnwebgpu port's WebGPU.importJsDevice() to wrap it in a C WGPUDevice handle.
	// Note: emdawnwebgpu is a thin JS wrapper around the browser's WebGPU API.
	// SPIR-V is NOT supported — we use Tint (C++, linked in) for SPIR-V → WGSL
	// conversion in shader_create_from_container() instead.
	// Create a WGPUInstance — needed for wgpuInstanceProcessEvents() which
	// processes async callbacks (buffer map readback, query results, etc.).
	WGPUInstanceDescriptor inst_desc = {};
	instance = wgpuCreateInstance(&inst_desc);
	if (!instance) {
		WARN_PRINT("WebGPU: wgpuCreateInstance returned null — async readback may not work.");
	}

	device = (WGPUDevice)(uintptr_t)EM_ASM_PTR({
		var d = Module["preinitializedWebGPUDevice"];
		if (!d) {
			return 0;
		}
		return WebGPU["importJsDevice"](d);
	});
	ERR_FAIL_COND_V_MSG(device == nullptr, ERR_CANT_CREATE, "WebGPU: Failed to get pre-initialized device. Ensure JS shell calls navigator.gpu.requestDevice() before WASM.");

	queue = wgpuDeviceGetQueue(device);
	ERR_FAIL_COND_V_MSG(queue == nullptr, ERR_CANT_CREATE, "WebGPU: Failed to get device queue.");

	// Populate device info from the adapter identity engine.js stashed on the device.
	//
	// ⚠ Everything RenderingServer.get_video_adapter_name() reports on web comes from
	// here, and it used to be the literal "WebGPU Device" on every machine. The four
	// GPUAdapterInfo fields are newline-joined on the JS side rather than fetched one at
	// a time, so this costs one call across the boundary. `device` and `description` are
	// gated behind a browser developer flag and are usually empty; the measured ceiling on
	// an Apple M5 in Chrome 151 is vendor "apple", architecture "metal-3". See WA-10-c.
	device_info.name = "WebGPU Device";
	device_info.vendor = Vendor::VENDOR_UNKNOWN;
	device_info.type = DEVICE_TYPE_INTEGRATED_GPU;

	char *adapter_info_utf8 = (char *)EM_ASM_PTR({
		var d = Module["preinitializedWebGPUDevice"];
		var info = (d && d["godotAdapterInfo"]) || null;
		if (!info) {
			return 0;
		}
		// ⚠ Concatenation, not an array join. EM_ASM is a macro, so the C preprocessor
		// splits its body on every top-level comma — and square brackets do not protect
		// one the way parentheses do.
		var joined = info["vendor"] + '\n' + info["architecture"] + '\n' + info["device"] + '\n' + info["description"];
		return stringToNewUTF8(joined);
	});
	if (adapter_info_utf8 != nullptr) {
		Vector<String> fields = String::utf8(adapter_info_utf8).split("\n", true);
		free(adapter_info_utf8);
		const String vendor_str = fields.size() > 0 ? fields[0].strip_edges() : String();
		const String arch_str = fields.size() > 1 ? fields[1].strip_edges() : String();
		const String device_str = fields.size() > 2 ? fields[2].strip_edges() : String();
		const String description_str = fields.size() > 3 ? fields[3].strip_edges() : String();

		// Prefer the specific names when the browser gives them, and fall back to the
		// vendor/architecture pair, which it almost always does.
		Vector<String> parts;
		if (!device_str.is_empty()) {
			parts.push_back(device_str);
		} else if (!description_str.is_empty()) {
			parts.push_back(description_str);
		}
		if (!vendor_str.is_empty()) {
			parts.push_back(vendor_str);
		}
		if (!arch_str.is_empty()) {
			parts.push_back(arch_str);
		}
		if (!parts.is_empty()) {
			device_info.name = String(" - ").join(parts);
		}

		if (vendor_str == "apple") {
			device_info.vendor = Vendor::VENDOR_APPLE;
		} else if (vendor_str == "nvidia") {
			device_info.vendor = Vendor::VENDOR_NVIDIA;
		} else if (vendor_str == "intel") {
			device_info.vendor = Vendor::VENDOR_INTEL;
		} else if (vendor_str == "amd") {
			device_info.vendor = Vendor::VENDOR_AMD;
		} else if (vendor_str == "arm") {
			device_info.vendor = Vendor::VENDOR_ARM;
		} else if (vendor_str == "qualcomm") {
			device_info.vendor = Vendor::VENDOR_QUALCOMM;
		} else if (vendor_str == "microsoft") {
			device_info.vendor = Vendor::VENDOR_MICROSOFT;
		}
	}
	print_verbose(vformat("WebGPU: adapter reported as '%s'.", device_info.name));

	print_verbose("WebGPU: Device imported from JS successfully.");
	return OK;
}

const RenderingContextDriver::Device &RenderingContextDriverWebGPU::device_get(uint32_t p_device_index) const {
	DEV_ASSERT(p_device_index == 0);
	return device_info;
}

uint32_t RenderingContextDriverWebGPU::device_get_count() const {
	return 1; // Browser exposes a single GPU context.
}

bool RenderingContextDriverWebGPU::device_supports_present(uint32_t p_device_index, SurfaceID p_surface) const {
	return true; // Single device always supports the canvas surface.
}

RenderingDeviceDriver *RenderingContextDriverWebGPU::driver_create() {
	return memnew(RenderingDeviceDriverWebGPU(this));
}

void RenderingContextDriverWebGPU::driver_free(RenderingDeviceDriver *p_driver) {
	memdelete(p_driver);
}

RenderingContextDriver::SurfaceID RenderingContextDriverWebGPU::surface_create(const void *p_platform_data) {
	// p_platform_data is expected to contain a canvas selector string (e.g., "#canvas").
	// For the web platform, we use the default canvas "#canvas".
	const char *canvas_selector = "#canvas";
	if (p_platform_data != nullptr) {
		// TODO: Extract canvas selector from platform data if provided.
		// For now, use default.
	}

	// Emscripten 5.x / emdawnwebgpu renamed this struct.
	WGPUEmscriptenSurfaceSourceCanvasHTMLSelector canvas_desc = {};
	canvas_desc.chain.sType = WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector;
	canvas_desc.selector = WGPUStringView{ canvas_selector, WGPU_STRLEN };

	WGPUSurfaceDescriptor surface_desc = {};
	surface_desc.nextInChain = (WGPUChainedStruct *)&canvas_desc;

	// Note: We need an instance to create a surface. If we don't have one,
	// create a minimal one. In Emscripten, the instance is a lightweight wrapper.
	if (instance == nullptr) {
		WGPUInstanceDescriptor inst_desc = {};
		instance = wgpuCreateInstance(&inst_desc);
	}

	WGPUSurface wgpu_surface = wgpuInstanceCreateSurface(instance, &surface_desc);
	ERR_FAIL_COND_V_MSG(wgpu_surface == nullptr, 0, "WebGPU: Failed to create surface from canvas.");

	SurfaceID id = next_surface_id++;
	Surface &surface = surfaces[id];
	surface.handle = wgpu_surface;
	surface.width = 0;
	surface.height = 0;
	surface.needs_resize = true;

	return id;
}

void RenderingContextDriverWebGPU::surface_set_size(SurfaceID p_surface, uint32_t p_width, uint32_t p_height) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	Surface &surface = surfaces[p_surface];
	if (surface.width != p_width || surface.height != p_height) {
		surface.width = p_width;
		surface.height = p_height;
		surface.needs_resize = true;
	}
}

void RenderingContextDriverWebGPU::surface_set_vsync_mode(SurfaceID p_surface, DisplayServerEnums::VSyncMode p_vsync_mode) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].vsync_mode = p_vsync_mode;
}

DisplayServerEnums::VSyncMode RenderingContextDriverWebGPU::surface_get_vsync_mode(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), DisplayServerEnums::VSYNC_ENABLED);
	return surfaces[p_surface].vsync_mode;
}

// --- HDR output ---
//
// The swap chain configures the canvas with `WGPUSurfaceColorManagement { SRGB, Extended }` when
// HDR is on (see RenderingDeviceDriverWebGPU::swap_chain_resize), so a value above 1.0 encoded by
// the final blit survives to the compositor instead of being clamped. The engine colour path does not change: web always reports
// COLOR_SPACE_REC709_NONLINEAR_SRGB, the tonemapper still writes linear into the RGBA16F render
// target, and `linear_to_srgb` in blit.glsl encodes without a clamp -- which is exactly the
// extended-sRGB encoding an `extended` canvas decodes. Enabling HDR only widens the range that
// survives, by way of `surface_get_hdr_output_max_value()` and the swap chain's format.
//
// ⚠ The luminance numbers below are notional. No web API reports a display's real HDR headroom:
// there is no nits query anywhere in the WebGPU or CSS surface, and macOS EDR headroom is dynamic
// -- at full SDR brightness a panel has almost none, at half brightness it has a lot. Only the
// ratio max/reference reaches a shader. The defaults are deliberately conservative (2.0 rather
// than the 4.0 a 400-nit panel assumption would give): over-assuming headroom puts tonemapped
// detail where the compositor clamps it, while under-assuming only leaves brightness unused.
// A project that wants better can ship a calibration screen against the stock
// `window_set_hdr_output_max_luminance()` API, which lands here.

void RenderingContextDriverWebGPU::surface_set_hdr_output_enabled(SurfaceID p_surface, bool p_enabled) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].hdr_output_enabled = p_enabled;
}

bool RenderingContextDriverWebGPU::surface_get_hdr_output_enabled(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), false);
	return surfaces[p_surface].hdr_output_enabled;
}

void RenderingContextDriverWebGPU::surface_set_hdr_output_reference_luminance(SurfaceID p_surface, float p_reference_luminance) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].hdr_reference_luminance = MAX(p_reference_luminance, 1.0f);
}

float RenderingContextDriverWebGPU::surface_get_hdr_output_reference_luminance(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 100.0f);
	return surfaces[p_surface].hdr_reference_luminance;
}

void RenderingContextDriverWebGPU::surface_set_hdr_output_max_luminance(SurfaceID p_surface, float p_max_luminance) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].hdr_max_luminance = MAX(p_max_luminance, 1.0f);
}

float RenderingContextDriverWebGPU::surface_get_hdr_output_max_luminance(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 200.0f);
	return surfaces[p_surface].hdr_max_luminance;
}

void RenderingContextDriverWebGPU::surface_set_hdr_output_linear_luminance_scale(SurfaceID p_surface, float p_linear_luminance_scale) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].hdr_linear_luminance_scale = MAX(p_linear_luminance_scale, 1.0f);
}

float RenderingContextDriverWebGPU::surface_get_hdr_output_linear_luminance_scale(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 100.0f);
	return surfaces[p_surface].hdr_linear_luminance_scale;
}

// 1.0 whenever HDR is off, which is the SDR maximum linear value and the floor the native
// backends clamp this ratio to as well -- so an SDR web frame stays bit-identical to one from
// before any of this existed.
float RenderingContextDriverWebGPU::surface_get_hdr_output_max_value(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 1.0f);
	const Surface &surface = surfaces[p_surface];
	if (!surface.hdr_output_enabled) {
		return 1.0f;
	}
	return MAX(surface.hdr_max_luminance / surface.hdr_reference_luminance, 1.0f);
}

uint32_t RenderingContextDriverWebGPU::surface_get_width(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 0);
	return surfaces[p_surface].width;
}

uint32_t RenderingContextDriverWebGPU::surface_get_height(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), 0);
	return surfaces[p_surface].height;
}

void RenderingContextDriverWebGPU::surface_set_needs_resize(SurfaceID p_surface, bool p_needs_resize) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	surfaces[p_surface].needs_resize = p_needs_resize;
}

bool RenderingContextDriverWebGPU::surface_get_needs_resize(SurfaceID p_surface) const {
	ERR_FAIL_COND_V(!surfaces.has(p_surface), false);
	return surfaces[p_surface].needs_resize;
}

void RenderingContextDriverWebGPU::surface_destroy(SurfaceID p_surface) {
	ERR_FAIL_COND(!surfaces.has(p_surface));
	Surface &surface = surfaces[p_surface];
	if (surface.handle) {
		wgpuSurfaceRelease(surface.handle);
	}
	surfaces.erase(p_surface);
}

bool RenderingContextDriverWebGPU::is_debug_utils_enabled() const {
	return false; // No debug utils in browser WebGPU.
}

WGPUSurface RenderingContextDriverWebGPU::surface_get_handle(SurfaceID p_surface) const {
	const Surface *s = surfaces.getptr(p_surface);
	ERR_FAIL_COND_V(s == nullptr, nullptr);
	return s->handle;
}

#endif // WEBGPU_ENABLED
