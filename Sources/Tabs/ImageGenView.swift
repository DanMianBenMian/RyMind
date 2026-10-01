import SwiftUI
import PhotosUI
import WebKit

/// 生图管线：本地 JS + Canvas，100% 离线，不联网、不等服务器。
/// （真扩散模型要 1.5GB+ 的 Core ML 权重，那是下一步；先把这条真能出图的管线打通。）
final class CanvasGen: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero)
    private var ready = false

    static let html = """
    <!doctype html><meta charset="utf-8"><body style="margin:0;background:#000"></body>
    <canvas id="c" width="8" height="8"></canvas>
    <script>
      function mulberry(a){return function(){a|=0;a=a+0x6D2B79F5|0;var t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
      window.gen = function(prompt, seed, size, pal, style){
        var c=document.getElementById('c'); c.width=size; c.height=size;
        var x=c.getContext('2d');
        var rnd=mulberry((seed*2654435761)>>>0);
        var p=String(prompt||'');
        function has(re){ try { return re.test(p); } catch(e){ return false; } }
        var warm = has(/暖|红|橙|黄|sun|sunset|fire|落日/);
        var dark = has(/暗|夜|黑|雨|moody|night|dark|冷/);
        var round= has(/圆|球|太阳|sun|moon|月亮|orb|球/);
        var wide = has(/大|宽|展开|wide|horizon|海|sky|天空|山|mountain/);
        var tech = has(/科技| cyber|霓虹|neon|futuristic|未来|pixel|像素/);
        var key = warm?18 : (dark?235 : (tech?285 : 205));
        var r0=pal?pal[0]:key, g0=pal?pal[1]:(key+40)%360, b0=pal?pal[2]:(key+200)%360;
        console.log('style');
        var g=x.createLinearGradient(0,0,size,size);
        g.addColorStop(0,'hsl('+r0+',65%,18%)');
        g.addColorStop(1,'hsl('+b0+',70%,'+(dark?'25%':'42%')+')');
        x.fillStyle=g; x.fillRect(0,0,size,size);

        // 大块柔和光斑
        for(var i=0;i<7;i++){
          var cx=rnd()*size, cy=rnd()*size, rad=size*(0.15+rnd()*0.45);
          var hue=(r0+i*22)%360;
          var rg=x.createRadialGradient(cx,cy,0,cx,cy,rad);
          rg.addColorStop(0,'hsla('+hue+',80%,60%,0.55)');
          rg.addColorStop(1,'hsla('+hue+',80%,60%,0)');
          x.fillStyle=rg; x.beginPath(); x.arc(cx,cy,rad,0,6.2832); x.fill();
        }
        // 主体：太阳 / 月亮 / 地平线
        if(round){
          var sx=size*(0.3+rnd()*0.4), sy=size*(0.3+rnd()*0.4), sr=size*0.18;
          x.fillStyle='hsla('+((r0+40)%360)+',95%,70%,0.95)';
          x.beginPath(); x.arc(sx,sy,sr,0,6.2832); x.fill();
        }
        if(wide){
          x.strokeStyle='hsla('+((b0+30)%360)+',60%,70%,0.5)';
          x.lineWidth=size*0.012;
          x.beginPath(); x.moveTo(0,size*(0.6+0.2*rnd())); x.lineTo(size,size*(0.5+0.2*rnd())); x.stroke();
        }
        // 风格叠加
        if(style===1){ // 水墨：去饱和 + 笔触
          x.globalCompositeOperation='saturation';
          x.fillStyle='hsl(0,0%,50%)'; x.fillRect(0,0,size,size);
          x.globalCompositeOperation='source-over';
        } else if(style===2){ // 赛博网格
          x.strokeStyle='rgba(255,60,200,0.35)'; x.lineWidth=1;
          for(var i=0;i<size;i+=size/24){ x.beginPath(); x.moveTo(i,0); x.lineTo(i,size); x.stroke(); x.beginPath(); x.moveTo(0,i); x.lineTo(size,i); x.stroke(); }
        } else { // 霓虹描边
          x.strokeStyle='hsla('+((r0+120)%360)+',95%,65%,0.7)'; x.lineWidth=size*0.006;
          for(var k=0;k<6;k++){ x.beginPath(); x.arc(size*(0.2+0.6*rnd()),size*(0.2+0.6*rnd()),size*(0.1+0.3*rnd()),0,6.2832); x.stroke(); }
        }
        // 噪点
        for(var n=0;n<size*3;n++){
          x.fillStyle='rgba(255,255,255,'+(rnd()*0.08)+')';
          x.fillRect(rnd()*size,rnd()*size,1,1);
        }
        return c.toDataURL('image/png');
      };
    </script>
    """

    override init() {
        super.init()
        web.isHidden = true
        web.navigationDelegate = self
        web.loadHTMLString(CanvasGen.html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true }

    /// 返回 PNG 的 Data
    func png(prompt: String, seed: Int, size: Int, palette: (Int, Int, Int)?, style: Int) -> Data? {
        var dataURL: String?
        for _ in 0..<30 {
            if ready { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let pal = palette.map { "[\($0.0),\($0.1),\($0.2)]" } ?? "null"
        let js = "gen(\(quote(prompt)), \(seed), \(size), \(pal), \(style))"
        var finished = false
        web.evaluateJavaScript(js) { res, _ in
            if let r = res as? String { dataURL = r }
            finished = true
        }
        for _ in 0..<50 where !finished { Thread.sleep(forTimeInterval: 0.05) }
        guard let s = dataURL, let i = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: i)...])
        return try? Data(base64Encoded: b64)
    }

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }
}

struct ImageGenView: View {
    @EnvironmentObject private var lock: TaskLock
    @State private var gen = CanvasGen()
    @State private var prompt = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var reference: UIImage?
    @State private var running = false
    @State private var stage = ""
    @State private var results: [UIImage] = []
    @State private var previewItem: ImagePreviewItem?
    @State private var showShare = false
    @State private var seed = Int(Date().timeIntervalSince1970) % 100000
    @State private var side = 512
    @State private var style = 0
    @State private var seedManual = false

    private let styles = ["默认", "水墨", "赛博网格"]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ModelPicker(kind: .image)
                Spacer()
                if lock.holder == .image {
                    Text("生成中").font(.system(size: 11)).foregroundStyle(RMTheme.warn)
                }
            }

            PhotosPicker(selection: $pickedItem, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RMTheme.surface, lineWidth: 1)
                        .frame(height: 118)
                    if let img = reference {
                        Image(uiImage: img).resizable().scaledToFill().frame(height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 20))
                            Text("参考图（取它的配色）").font(.system(size: 12))
                        }
                        .foregroundStyle(RMTheme.textSub)
                    }
                }
            }
            .onChange(of: pickedItem) { item in
                guard let item = item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    guard let data = data, let img = UIImage(data: data) else { return }
                    DispatchQueue.main.async { self.reference = img }
                }
            }

            TextField("描述想生成的画面…", text: $prompt, axis: .vertical)
                .font(.system(size: 13))
                .foregroundStyle(RMTheme.text)
                .lineLimit(2...4)
                .padding(11)
                .background(RMTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Picker("", selection: $side) {
                    Text("512").tag(512)
                    Text("768").tag(768)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Picker("", selection: $style) {
                    ForEach(styles, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .font(.system(size: 12))

            HStack(spacing: 10) {
                Button {
                    seed = Int(Date().timeIntervalSince1970) % 100000
                    seedManual = false
                } label: {
                    Label("换种子", systemImage: "shuffle")
                        .font(.system(size: 12))
                        .foregroundStyle(RMTheme.accent)
                }
                Text("seed \(seed)")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
                Spacer()
                TextField("手动种子", text: Binding(
                    get: { String(seed) },
                    set: { v in if let n = Int(v) { seed = n; seedManual = true } }
                ))
                .keyboardType(.numberPad)
                .frame(width: 100)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RMTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Button { start() } label: {
                Text(running ? "生成中…" : "开始生成")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: 0x0B1F1B))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(running ? RMTheme.textSub : RMTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(running)

            if running { ProgressView(value: 0.7).tint(RMTheme.accent) }
            if !stage.isEmpty {
                Text(stage).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, img in
                        Button { previewItem = ImagePreviewItem(image: img) } label: {
                            Image(uiImage: img).resizable().scaledToFit()
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            Spacer().frame(height: 4)
        }
        .padding(14)
        .background(RMTheme.bg)
        .sheet(item: $previewItem) { item in ImagePreviewSheet(img: item.image) }
    }

    private func start() {
        guard lock.acquire(.image) else { return }
        running = true
        stage = "读取描述…"
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let pal = reference.map { CanvasGen.averageColor(of: $0) }

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async { self.stage = "本地生成（JS + Canvas，离线）" }
            let data = gen.png(prompt: p.isEmpty ? "untitled" : p, seed: seed, size: side, palette: pal, style: style)
            let img = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                running = false
                if let img = img, let d = data {
                    results.insert(img, at: 0)
                    // 顺手存一份到工作空间的 studio 目录
                    FileStore.shared.writeData(name: "studio/rmind-\(seed)-\(results.count).png", data: d)
                } else {
                    stage = "生成失败，再试一次"
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                        DispatchQueue.main.async { self.stage = "" }
                    }
                }
                lock.release(.image)
            }
        }
    }
}

struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImagePreviewSheet: View {
    let img: UIImage
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Image(uiImage: img).resizable().scaledToFit().padding(12)
                HStack(spacing: 14) {
                    Button { showShare = true } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    Button {
                        if let d = img.pngData() { FileStore.shared.writeData(name: "studio/save-\(Date().timeIntervalSince1970).png", data: d) }
                    } label: { Label("存入工作空间", systemImage: "folder") }
                    Button("关闭") {}
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 16)
            }
            .background(RMTheme.bg)
            .sheet(isPresented: $showShare) {
                ActivityView(activityItems: [img.pngData() ?? Data()] as [Any])
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension CanvasGen {
    /// 参考图主色（缩到 1×1 取像素）
    static func averageColor(of img: UIImage) -> (Int, Int, Int) {
        let one = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard let cg = one.cgImage,
              let prov = cg.dataProvider,
              let cf = prov.data,
              let raw = cf as Data?, raw.count >= 4 else { return (205, 90, 60) }
        let b = [UInt8](raw) 
        return (Int(b[0]), Int(b[1]), Int(b[2]))
    }
}
