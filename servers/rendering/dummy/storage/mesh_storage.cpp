/**************************************************************************/
/*  mesh_storage.cpp                                                      */
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

#include "mesh_storage.h"

using namespace RendererDummy;

MeshStorage *MeshStorage::singleton = nullptr;

MeshStorage::MeshStorage() {
	singleton = this;
}

MeshStorage::~MeshStorage() {
	singleton = nullptr;
}

RID MeshStorage::mesh_allocate() {
	return mesh_owner.allocate_rid();
}

void MeshStorage::mesh_initialize(RID p_rid) {
	mesh_owner.initialize_rid(p_rid, DummyMesh());
}

void MeshStorage::mesh_free(RID p_rid) {
	DummyMesh *mesh = mesh_owner.get_or_null(p_rid);
	ERR_FAIL_NULL(mesh);
	mesh->dependency.deleted_notify(p_rid);
	mesh_owner.free(p_rid);
}

void MeshStorage::mesh_surface_remove(RID p_mesh, int p_surface) {
	DummyMesh *m = mesh_owner.get_or_null(p_mesh);
	ERR_FAIL_NULL(m);
	m->dependency.changed_notify(Dependency::DEPENDENCY_CHANGED_MESH);
	m->surfaces.remove_at(p_surface);
}

void MeshStorage::mesh_clear(RID p_mesh) {
	DummyMesh *m = mesh_owner.get_or_null(p_mesh);
	ERR_FAIL_NULL(m);

	m->surfaces.clear();
}

RID MeshStorage::_multimesh_allocate() {
	return multimesh_owner.allocate_rid();
}

void MeshStorage::_multimesh_initialize(RID p_rid) {
	multimesh_owner.initialize_rid(p_rid, DummyMultiMesh());
}

void MeshStorage::_multimesh_free(RID p_rid) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_rid);
	ERR_FAIL_NULL(multimesh);

	multimesh_owner.free(p_rid);
}

void MeshStorage::_multimesh_allocate_data(RID p_multimesh, int p_instances, RSE::MultimeshTransformFormat p_transform_format, bool p_use_colors, bool p_use_custom_data, bool p_use_indirect) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL(multimesh);

	if (multimesh->instances == p_instances && multimesh->xform_format == p_transform_format && multimesh->uses_colors == p_use_colors && multimesh->uses_custom_data == p_use_custom_data) {
		return;
	}

	multimesh->instances = p_instances;
	multimesh->xform_format = p_transform_format;
	multimesh->uses_colors = p_use_colors;
	multimesh->uses_custom_data = p_use_custom_data;
	multimesh->color_offset = p_transform_format == RSE::MULTIMESH_TRANSFORM_2D ? 8 : 12;
	multimesh->custom_data_offset = multimesh->color_offset + (p_use_colors ? 4 : 0);
	multimesh->stride = multimesh->custom_data_offset + (p_use_custom_data ? 4 : 0);
	multimesh->buffer = PackedFloat32Array();
}

int MeshStorage::_multimesh_get_instance_count(RID p_multimesh) const {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL_V(multimesh, 0);
	return multimesh->instances;
}

float *MeshStorage::_multimesh_instance_write(DummyMultiMesh *p_multimesh, int p_index) {
	if (p_multimesh->buffer.is_empty()) {
		p_multimesh->buffer.resize_initialized(p_multimesh->instances * p_multimesh->stride);
	}
	return p_multimesh->buffer.ptrw() + p_index * p_multimesh->stride;
}

const float *MeshStorage::_multimesh_instance_read(const DummyMultiMesh *p_multimesh, int p_index) const {
	if (p_multimesh->buffer.is_empty()) {
		return nullptr;
	}
	return p_multimesh->buffer.ptr() + p_index * p_multimesh->stride;
}

void MeshStorage::_multimesh_instance_set_transform(RID p_multimesh, int p_index, const Transform3D &p_transform) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL(multimesh);
	ERR_FAIL_INDEX(p_index, multimesh->instances);
	ERR_FAIL_COND(multimesh->xform_format != RSE::MULTIMESH_TRANSFORM_3D);

	float *dataptr = _multimesh_instance_write(multimesh, p_index);
	dataptr[0] = p_transform.basis.rows[0][0];
	dataptr[1] = p_transform.basis.rows[0][1];
	dataptr[2] = p_transform.basis.rows[0][2];
	dataptr[3] = p_transform.origin.x;
	dataptr[4] = p_transform.basis.rows[1][0];
	dataptr[5] = p_transform.basis.rows[1][1];
	dataptr[6] = p_transform.basis.rows[1][2];
	dataptr[7] = p_transform.origin.y;
	dataptr[8] = p_transform.basis.rows[2][0];
	dataptr[9] = p_transform.basis.rows[2][1];
	dataptr[10] = p_transform.basis.rows[2][2];
	dataptr[11] = p_transform.origin.z;
}

void MeshStorage::_multimesh_instance_set_transform_2d(RID p_multimesh, int p_index, const Transform2D &p_transform) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL(multimesh);
	ERR_FAIL_INDEX(p_index, multimesh->instances);
	ERR_FAIL_COND(multimesh->xform_format != RSE::MULTIMESH_TRANSFORM_2D);

	float *dataptr = _multimesh_instance_write(multimesh, p_index);
	dataptr[0] = p_transform.columns[0][0];
	dataptr[1] = p_transform.columns[1][0];
	dataptr[2] = 0;
	dataptr[3] = p_transform.columns[2][0];
	dataptr[4] = p_transform.columns[0][1];
	dataptr[5] = p_transform.columns[1][1];
	dataptr[6] = 0;
	dataptr[7] = p_transform.columns[2][1];
}

void MeshStorage::_multimesh_instance_set_color(RID p_multimesh, int p_index, const Color &p_color) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL(multimesh);
	ERR_FAIL_INDEX(p_index, multimesh->instances);
	ERR_FAIL_COND(!multimesh->uses_colors);

	float *dataptr = _multimesh_instance_write(multimesh, p_index) + multimesh->color_offset;
	dataptr[0] = p_color.r;
	dataptr[1] = p_color.g;
	dataptr[2] = p_color.b;
	dataptr[3] = p_color.a;
}

void MeshStorage::_multimesh_instance_set_custom_data(RID p_multimesh, int p_index, const Color &p_color) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL(multimesh);
	ERR_FAIL_INDEX(p_index, multimesh->instances);
	ERR_FAIL_COND(!multimesh->uses_custom_data);

	float *dataptr = _multimesh_instance_write(multimesh, p_index) + multimesh->custom_data_offset;
	dataptr[0] = p_color.r;
	dataptr[1] = p_color.g;
	dataptr[2] = p_color.b;
	dataptr[3] = p_color.a;
}

Transform3D MeshStorage::_multimesh_instance_get_transform(RID p_multimesh, int p_index) const {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL_V(multimesh, Transform3D());
	ERR_FAIL_INDEX_V(p_index, multimesh->instances, Transform3D());
	ERR_FAIL_COND_V(multimesh->xform_format != RSE::MULTIMESH_TRANSFORM_3D, Transform3D());

	const float *dataptr = _multimesh_instance_read(multimesh, p_index);
	if (!dataptr) {
		return Transform3D();
	}
	Transform3D t;
	t.basis.rows[0][0] = dataptr[0];
	t.basis.rows[0][1] = dataptr[1];
	t.basis.rows[0][2] = dataptr[2];
	t.origin.x = dataptr[3];
	t.basis.rows[1][0] = dataptr[4];
	t.basis.rows[1][1] = dataptr[5];
	t.basis.rows[1][2] = dataptr[6];
	t.origin.y = dataptr[7];
	t.basis.rows[2][0] = dataptr[8];
	t.basis.rows[2][1] = dataptr[9];
	t.basis.rows[2][2] = dataptr[10];
	t.origin.z = dataptr[11];
	return t;
}

Transform2D MeshStorage::_multimesh_instance_get_transform_2d(RID p_multimesh, int p_index) const {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL_V(multimesh, Transform2D());
	ERR_FAIL_INDEX_V(p_index, multimesh->instances, Transform2D());
	ERR_FAIL_COND_V(multimesh->xform_format != RSE::MULTIMESH_TRANSFORM_2D, Transform2D());

	const float *dataptr = _multimesh_instance_read(multimesh, p_index);
	if (!dataptr) {
		return Transform2D();
	}
	Transform2D t;
	t.columns[0][0] = dataptr[0];
	t.columns[1][0] = dataptr[1];
	t.columns[2][0] = dataptr[3];
	t.columns[0][1] = dataptr[4];
	t.columns[1][1] = dataptr[5];
	t.columns[2][1] = dataptr[7];
	return t;
}

Color MeshStorage::_multimesh_instance_get_color(RID p_multimesh, int p_index) const {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL_V(multimesh, Color());
	ERR_FAIL_INDEX_V(p_index, multimesh->instances, Color());
	ERR_FAIL_COND_V(!multimesh->uses_colors, Color());

	const float *dataptr = _multimesh_instance_read(multimesh, p_index);
	if (!dataptr) {
		return Color();
	}
	dataptr += multimesh->color_offset;
	return Color(dataptr[0], dataptr[1], dataptr[2], dataptr[3]);
}

Color MeshStorage::_multimesh_instance_get_custom_data(RID p_multimesh, int p_index) const {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL_V(multimesh, Color());
	ERR_FAIL_INDEX_V(p_index, multimesh->instances, Color());
	ERR_FAIL_COND_V(!multimesh->uses_custom_data, Color());

	const float *dataptr = _multimesh_instance_read(multimesh, p_index);
	if (!dataptr) {
		return Color();
	}
	dataptr += multimesh->custom_data_offset;
	return Color(dataptr[0], dataptr[1], dataptr[2], dataptr[3]);
}

void MeshStorage::_multimesh_set_buffer(RID p_multimesh, const Vector<float> &p_buffer) {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL(multimesh);
	ERR_FAIL_COND(p_buffer.size() != multimesh->instances * (int)multimesh->stride);
	multimesh->buffer = p_buffer;
}

Vector<float> MeshStorage::_multimesh_get_buffer(RID p_multimesh) const {
	DummyMultiMesh *multimesh = multimesh_owner.get_or_null(p_multimesh);
	ERR_FAIL_NULL_V(multimesh, Vector<float>());
	if (multimesh->buffer.is_empty() && multimesh->instances > 0) {
		// Like the real renderers, an unwritten buffer reads as zeros.
		Vector<float> zeros;
		zeros.resize_initialized(multimesh->instances * multimesh->stride);
		return zeros;
	}
	return multimesh->buffer;
}
