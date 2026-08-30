/**************************************************************************/
/*  main.cpp                                                              */
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

// tint_convert_cli — Standalone SPIR-V → WGSL converter for build-time precompilation.
//
// Runs the same 13 preprocessing passes as the Godot WebGPU runtime driver,
// then converts to WGSL via Tint. Produces output identical to what the engine
// generates at runtime, enabling precompilation of ubershader and specialized
// shader variants at build time.
//
// Usage:
//   tint_convert_cli <file.spv>                       # single file → WGSL to stdout
//   tint_convert_cli --batch <file1.spv> <file2.spv>  # batch → JSON to stdout
//   tint_convert_cli --overrides ...                  # keep spec constants as WGSL overrides
//   tint_convert_cli --pipeline-id                    # print the translation-pipeline stamp
//
// --overrides skips freeze_spec_constant_ops, so Tint's reader emits
// `@id(N) override` declarations instead of frozen defaults; the engine then
// specializes pipelines with WGPUConstantEntry values at pipeline creation.
//
// --pipeline-id prints the hash build.sh computed over the files listed in
// pipeline_id_inputs.txt. The editor bakes WGSL only when this stamp matches
// the one it was built with; a stale CLI degrades the bake to SPIR-V-only.

#include "drivers/webgpu/spirv_preprocess.h"
#include "drivers/webgpu/tint_wrapper.h"

#ifndef TINT_CLI_PIPELINE_ID
#define TINT_CLI_PIPELINE_ID "unstamped"
#endif

#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

// Read a binary file into a byte vector.
static std::vector<uint8_t> read_file(const char *p_path) {
	std::ifstream f(p_path, std::ios::binary | std::ios::ate);
	if (!f.is_open()) {
		return {};
	}
	auto size = f.tellg();
	if (size <= 0) {
		return {};
	}
	std::vector<uint8_t> buf((size_t)size);
	f.seekg(0);
	f.read(reinterpret_cast<char *>(buf.data()), size);
	return buf;
}

// When true (--overrides), freeze_spec_constant_ops is skipped so spec
// constants survive into Tint and come out as `@id(N) override` declarations.
static bool g_keep_overrides = false;

// Run the full SPIR-V preprocessing pipeline + Tint conversion.
// Returns WGSL string on success, empty string on failure (error written to r_error).
static std::string convert_spirv_to_wgsl(const std::vector<uint8_t> &p_spv_bytes, std::string &r_error) {
	if (p_spv_bytes.size() < 20 || (p_spv_bytes.size() % 4) != 0) {
		r_error = "Invalid SPIR-V: too small or not aligned to 4 bytes";
		return {};
	}

	// Wrap in Godot-compatible Vector for the preprocessing API.
	Vector<uint8_t> spv;
	spv.resize((int64_t)p_spv_bytes.size());
	memcpy(spv.ptrw(), p_spv_bytes.data(), p_spv_bytes.size());

	// The preprocessing pipeline, in the one order every consumer shares — the
	// runtime driver, this CLI and the Tint worker. --overrides skips the freeze.
	spv = spirv_preprocess::run_translation_passes(spv, g_keep_overrides);

	// Ensure SPIR-V version is at least 1.3 (0x00010300). The preprocessing
	// passes produce constructs (StorageBuffer storage class) that require 1.3,
	// but input SPIR-V may declare an older version in its header.
	if (spv.size() >= 20) {
		uint32_t version;
		memcpy(&version, spv.ptr() + 4, 4);
		if (version < 0x00010300) {
			version = 0x00010300;
			memcpy(spv.ptrw() + 4, &version, 4);
		}
	}

	// Convert to uint32_t words for Tint.
	size_t word_count = (size_t)spv.size() / 4;
	const uint32_t *words = reinterpret_cast<const uint32_t *>(spv.ptr());

	char *error_msg = nullptr;
	char *wgsl = tint_wrapper_spirv_to_wgsl(words, word_count, &error_msg);
	if (!wgsl) {
		r_error = error_msg ? error_msg : "Tint conversion failed (unknown error)";
		free(error_msg);
		return {};
	}

	std::string result(wgsl);
	free(wgsl);
	return result;
}

// Escape a string for JSON output (handles \, ", newlines, tabs).
static std::string json_escape(const std::string &p_str) {
	std::string out;
	out.reserve(p_str.size() + p_str.size() / 8);
	for (char c : p_str) {
		switch (c) {
			case '"':
				out += "\\\"";
				break;
			case '\\':
				out += "\\\\";
				break;
			case '\n':
				out += "\\n";
				break;
			case '\r':
				out += "\\r";
				break;
			case '\t':
				out += "\\t";
				break;
			default:
				out += c;
				break;
		}
	}
	return out;
}

// Convert a single file in a forked child process. Tint can abort() on
// unhandled SPIR-V features (TINT_UNIMPLEMENTED); fork isolation prevents
// one bad shader from killing the entire batch.
//
// Returns WGSL on success, or sets r_error on failure.
static std::string convert_isolated(const std::vector<uint8_t> &p_spv_bytes, std::string &r_error) {
	// Create a pipe for the child to send results back.
	int pipefd[2];
	if (pipe(pipefd) != 0) {
		// Fallback: convert in-process if pipe fails.
		return convert_spirv_to_wgsl(p_spv_bytes, r_error);
	}

	// Flush parent's stdout before forking so the child doesn't
	// inherit any buffered data.
	fflush(stdout);
	std::cout.flush();

	pid_t pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		return convert_spirv_to_wgsl(p_spv_bytes, r_error);
	}

	if (pid == 0) {
		// Child process.
		close(pipefd[0]); // Close read end.

		// Redirect stdout/stderr to /dev/null so Tint crash messages and
		// C++ runtime flush on abort() don't corrupt the parent's JSON
		// output stream. Don't use fclose() — it flushes the parent's
		// buffered cout data (copied on fork), duplicating output.
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}

		std::string err;
		std::string wgsl = convert_spirv_to_wgsl(p_spv_bytes, err);

		// Protocol: first byte is status ('W' = wgsl, 'E' = error).
		if (!wgsl.empty()) {
			char status = 'W';
			write(pipefd[1], &status, 1);
			write(pipefd[1], wgsl.data(), wgsl.size());
		} else {
			char status = 'E';
			write(pipefd[1], &status, 1);
			write(pipefd[1], err.data(), err.size());
		}
		close(pipefd[1]);
		_exit(0);
	}

	// Parent process.
	close(pipefd[1]); // Close write end.

	// Read all data from child.
	std::string data;
	char buf[4096];
	ssize_t n;
	while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
		data.append(buf, (size_t)n);
	}
	close(pipefd[0]);

	int status;
	waitpid(pid, &status, 0);

	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || data.empty()) {
		r_error = "Tint crashed (likely TINT_UNIMPLEMENTED on unsupported SPIR-V feature)";
		return {};
	}

	if (data[0] == 'W') {
		return data.substr(1);
	} else {
		r_error = data.substr(1);
		return {};
	}
}

static void print_usage() {
	fprintf(stderr, "Usage:\n");
	fprintf(stderr, "  tint_convert_cli [--overrides] <file.spv>                       Single file → WGSL to stdout\n");
	fprintf(stderr, "  tint_convert_cli [--overrides] --batch <file1.spv> [file2.spv]  Batch → JSON to stdout\n");
	fprintf(stderr, "  tint_convert_cli --pipeline-id                                  Print translation-pipeline stamp\n");
}

int main(int argc, char *argv[]) {
	// Collect file arguments; flags may appear anywhere before them.
	bool batch_mode = false;
	std::vector<const char *> files;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--pipeline-id") == 0) {
			printf("%s\n", TINT_CLI_PIPELINE_ID);
			return 0;
		} else if (strcmp(argv[i], "--overrides") == 0) {
			g_keep_overrides = true;
		} else if (strcmp(argv[i], "--batch") == 0) {
			batch_mode = true;
		} else {
			files.push_back(argv[i]);
		}
	}

	if (files.empty()) {
		print_usage();
		return 1;
	}

	tint_wrapper_initialize();

	if (batch_mode) {
		// Batch mode: output JSON { "path": "wgsl" | {"error": "msg"}, ... }
		std::cout << "{" << std::endl;
		for (size_t i = 0; i < files.size(); i++) {
			const char *path = files[i];
			auto spv_bytes = read_file(path);

			std::cout << "  \"" << json_escape(path) << "\": ";

			if (spv_bytes.empty()) {
				std::cout << "{\"error\": \"Failed to read file\"}";
			} else {
				std::string error;
				std::string wgsl = convert_isolated(spv_bytes, error);
				if (wgsl.empty()) {
					std::cout << "{\"error\": \"" << json_escape(error) << "\"}";
				} else {
					std::cout << "\"" << json_escape(wgsl) << "\"";
				}
			}

			if (i + 1 < files.size()) {
				std::cout << ",";
			}
			std::cout << std::endl;
		}
		std::cout << "}" << std::endl;
		return 0;

	} else {
		// Single file mode: output WGSL to stdout.
		const char *path = files[0];
		auto spv_bytes = read_file(path);
		if (spv_bytes.empty()) {
			fprintf(stderr, "Error: Failed to read '%s'\n", path);
			return 1;
		}

		std::string error;
		std::string wgsl = convert_spirv_to_wgsl(spv_bytes, error);
		if (wgsl.empty()) {
			fprintf(stderr, "Error: %s\n", error.c_str());
			return 1;
		}

		std::cout << wgsl;
		return 0;
	}
}
