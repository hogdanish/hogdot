/**************************************************************************/
/*  test_multimesh.cpp                                                    */
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

TEST_FORCE_LINK(test_multimesh)

#include "scene/resources/multimesh.h"
#include "servers/rendering/rendering_server.h"

namespace TestMultiMesh {

// Runs on the dummy renderer, like every headless process.
TEST_CASE("[SceneTree][MultiMesh] Instance data reads back what was written") {
	Ref<MultiMesh> multimesh;
	multimesh.instantiate();
	multimesh->set_transform_format(MultiMesh::TRANSFORM_3D);
	multimesh->set_use_colors(true);
	multimesh->set_use_custom_data(true);
	multimesh->set_instance_count(3);

	const Transform3D transform(Basis::from_euler(Vector3(0.1, 0.2, 0.3)), Vector3(1, 2, 3));
	const Color color(0.1, 0.2, 0.3, 0.4);
	const Color custom_data(5, 6, 7, 8);

	SUBCASE("An unwritten instance reads as the identity, and the buffer as zeros") {
		CHECK(multimesh->get_instance_transform(1) == Transform3D());
		const Vector<float> buffer = RS::get_singleton()->multimesh_get_buffer(multimesh->get_rid());
		CHECK(buffer.size() == 3 * (12 + 4 + 4));
		CHECK(buffer[0] == 0.0f);
	}

	SUBCASE("Per-instance setters") {
		multimesh->set_instance_transform(1, transform);
		multimesh->set_instance_color(1, color);
		multimesh->set_instance_custom_data(1, custom_data);
		CHECK(multimesh->get_instance_transform(1).is_equal_approx(transform));
		CHECK(multimesh->get_instance_color(1).is_equal_approx(color));
		CHECK(multimesh->get_instance_custom_data(1).is_equal_approx(custom_data));

		// The buffer carries the same data, so a copy keeps it.
		Ref<MultiMesh> copy = multimesh->duplicate();
		CHECK(copy->get_instance_transform(1).is_equal_approx(transform));
	}

	SUBCASE("A new instance count drops the data") {
		multimesh->set_instance_transform(1, transform);
		multimesh->set_instance_count(2);
		CHECK(multimesh->get_instance_transform(1) == Transform3D());
	}
}

TEST_CASE("[SceneTree][MultiMesh] 2D instance transforms read back what was written") {
	Ref<MultiMesh> multimesh;
	multimesh.instantiate();
	multimesh->set_transform_format(MultiMesh::TRANSFORM_2D);
	multimesh->set_instance_count(2);

	const Transform2D transform(0.5, Size2(2, 3), 0.25, Vector2(4, 5));
	multimesh->set_instance_transform_2d(1, transform);
	CHECK(multimesh->get_instance_transform_2d(1).is_equal_approx(transform));
	CHECK(RS::get_singleton()->multimesh_get_buffer(multimesh->get_rid()).size() == 2 * 8);
}

} // namespace TestMultiMesh
