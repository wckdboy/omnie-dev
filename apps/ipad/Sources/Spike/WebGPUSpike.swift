// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit

/// P0 spike 4 (PLAN §25): WebGPU and WebGL2 inside a third-party WKWebView. Checks navigator.gpu,
/// gets an adapter and device, runs a compute shader and verifies its output, and renders with
/// WebGL2. Results come back over a script message handler and are saved as JSON in Documents.
struct WebGPUSpikeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = ["Running…"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WebView(onMessage: { message in
                    lines.append(message)
                    print("[webgpu]", message)
                    if message.hasPrefix("{") {
                        let url = URL.documentsDirectory.appendingPathComponent("webgpu-spike-\(Int(Date().timeIntervalSince1970)).json")
                        try? message.write(to: url, atomically: true, encoding: .utf8)
                        print("[webgpu] saved \(url.lastPathComponent)")
                    }
                })
                .frame(height: 240)
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            }
            .navigationTitle("WebGPU spike (P0)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }

    private struct WebView: UIViewRepresentable {
        let onMessage: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.userContentController.add(context.coordinator, name: "spike")
            let view = WKWebView(frame: .zero, configuration: config)
            view.isInspectable = true
            // WebGPU exists only in secure contexts; a nil base URL gives an opaque, insecure origin.
            view.loadHTMLString(Self.page, baseURL: URL(string: "https://stage.omnie.invalid/"))
            return view
        }

        func updateUIView(_ uiView: WKWebView, context: Context) {}

        final class Coordinator: NSObject, WKScriptMessageHandler {
            let onMessage: (String) -> Void
            init(onMessage: @escaping (String) -> Void) { self.onMessage = onMessage }
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                onMessage(String(describing: message.body))
            }
        }

        static let page = #"""
        <!doctype html><html><head><meta name="viewport" content="width=device-width"></head>
        <body style="margin:0;background:#111316">
        <canvas id="gl" width="300" height="200"></canvas>
        <script>
        const post = (m) => window.webkit.messageHandlers.spike.postMessage(m);
        const result = { userAgent: navigator.userAgent, isSecureContext: window.isSecureContext, origin: location.origin };
        async function webgpu() {
          result.navigatorGPU = !!navigator.gpu;
          if (!navigator.gpu) return;
          const adapter = await navigator.gpu.requestAdapter();
          result.adapter = !!adapter;
          if (!adapter) return;
          result.adapterInfo = adapter.info ? { vendor: adapter.info.vendor, architecture: adapter.info.architecture } : null;
          result.features = [...adapter.features].sort();
          result.limits = { maxBufferSize: adapter.limits.maxBufferSize, maxComputeWorkgroupSizeX: adapter.limits.maxComputeWorkgroupSizeX, maxStorageBufferBindingSize: adapter.limits.maxStorageBufferBindingSize };
          const device = await adapter.requestDevice();
          result.device = !!device;
          // Compute: square 1M floats and check the result.
          const n = 1 << 20;
          const input = new Float32Array(n).map((_, i) => i % 1000);
          const module = device.createShaderModule({ code: `
            @group(0) @binding(0) var<storage, read_write> data: array<f32>;
            @compute @workgroup_size(256) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
              if (id.x < arrayLength(&data)) { data[id.x] = data[id.x] * data[id.x]; }
            }` });
          const info = await module.getCompilationInfo();
          result.wgslMessages = info.messages.length;
          const buffer = device.createBuffer({ size: input.byteLength, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST });
          device.queue.writeBuffer(buffer, 0, input);
          const readback = device.createBuffer({ size: input.byteLength, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
          const pipeline = device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: "main" } });
          const bind = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer } }] });
          const t0 = performance.now();
          const enc = device.createCommandEncoder();
          const pass = enc.beginComputePass(); pass.setPipeline(pipeline); pass.setBindGroup(0, bind);
          pass.dispatchWorkgroups(Math.ceil(n / 256)); pass.end();
          enc.copyBufferToBuffer(buffer, 0, readback, 0, input.byteLength);
          device.queue.submit([enc.finish()]);
          await readback.mapAsync(GPUMapMode.READ);
          result.computeMs = +(performance.now() - t0).toFixed(2);
          const out = new Float32Array(readback.getMappedRange());
          result.computeCorrect = out[999] === 999 * 999 && out[n - 1] === ((n - 1) % 1000) ** 2;
        }
        function webgl2() {
          const gl = document.getElementById("gl").getContext("webgl2");
          result.webgl2 = !!gl;
          if (!gl) return;
          result.webgl2Renderer = gl.getParameter(gl.RENDERER);
          result.maxTextureSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
          gl.clearColor(0.24, 0.84, 0.96, 1); gl.clear(gl.COLOR_BUFFER_BIT);
          const px = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
          result.webgl2Draws = px[0] > 50 && px[2] > 200;
        }
        (async () => {
          try { webgl2(); } catch (e) { result.webgl2Error = String(e); }
          try { await webgpu(); } catch (e) { result.webgpuError = String(e); }
          post(JSON.stringify(result));
        })();
        </script></body></html>
        """#
    }
}
