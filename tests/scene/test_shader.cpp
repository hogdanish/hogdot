/**************************************************************************/
/*  test_shader.cpp                                                       */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_shader)

#include "scene/resources/shader.h"

namespace TestShader {

struct ErrorCapture {
	ErrorHandlerList eh;
	Vector<String> errors;

	static void _capture(void *p_self, const char *p_func, const char *p_file, int p_line, const char *p_error, const char *p_errorexp, bool p_editor_notify, ErrorHandlerType p_type) {
		static_cast<ErrorCapture *>(p_self)->errors.push_back(String::utf8(p_error) + " " + String::utf8(p_errorexp));
	}

	bool has(const String &p_text) const {
		for (const String &error : errors) {
			if (error.contains(p_text)) {
				return true;
			}
		}
		return false;
	}

	ErrorCapture() {
		eh.errfunc = _capture;
		eh.userdata = this;
		add_error_handler(&eh);
	}

	~ErrorCapture() {
		remove_error_handler(&eh);
	}
};

TEST_CASE("[SceneTree][Shader] A preprocessor error reports its own message") {
	Ref<Shader> shader;
	shader.instantiate();

	ErrorCapture capture;
	ERR_PRINT_OFF;
	shader->set_code("shader_type canvas_item;\n#error \"this shader needs a define\"\nvoid fragment() {}\n");
	shader->get_rid();
	ERR_PRINT_ON;

	CHECK(capture.has("this shader needs a define"));
	// The raw code is never compiled, so its `#` is not reported.
	CHECK_FALSE(capture.has("Unknown character"));
	CHECK(shader->get_mode() == Shader::MODE_CANVAS_ITEM);
}

} // namespace TestShader
