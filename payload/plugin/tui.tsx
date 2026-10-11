import { Plugin, usePlugin } from "@opencode/plugin/tui"
import { createSignal, onCleanup } from "solid-js"
import fs from "node:fs"
import path from "node:path"
import os from "node:os"

/**
 * OpenCode 语音输入 —— CLI/TUI 插件外壳。
 *
 * 说明：V2 的 CLI 插件 API 不能读取"按住/松开"按键事件，也不能把文字写进输入框，
 * 所以长按回车由系统层助手（voice.ahk）完成。这个插件提供：
 *   /voice         开始/停止录音，停止后把转写文字复制到剪贴板
 *   /voice-status  查看服务状态
 *   /voice-setup   选择麦克风、设置长按阈值
 *   底部状态栏显示 🎤 状态
 */

// ---------------------------------------------------------------- 本地配置
function readJson(file: string): any {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"))
  } catch {
    return null
  }
}

function pluginDir(): string {
  try {
    const url = new URL(import.meta.url)
    let p = decodeURIComponent(url.pathname)
    if (/^\/[A-Za-z]:/.test(p)) p = p.slice(1)          // Windows 盘符
    return path.dirname(p)
  } catch {
    return ""
  }
}

const here = pluginDir()
const localCfg = (here && readJson(path.join(here, "config.json"))) || {}
const installDir: string =
  localCfg.installDir || path.join(os.homedir(), ".config", "opencode", "voice")

function readPort(): number {
  if (localCfg.port) return Number(localCfg.port)
  try {
    const ini = fs.readFileSync(path.join(installDir, "voice.config.ini"), "utf8")
    const m = ini.match(/^\s*port\s*=\s*(\d+)/m)
    if (m) return Number(m[1])
  } catch {
    // 忽略：使用默认端口
  }
  return 17860
}

const PORT = readPort()
const BASE = `http://127.0.0.1:${PORT}`

// ---------------------------------------------------------------- HTTP
async function getJson(p: string): Promise<any | null> {
  try {
    const r = await fetch(BASE + p)
    if (!r.ok) return null
    return await r.json()
  } catch {
    return null
  }
}

async function postText(p: string, body = ""): Promise<{ status: number; text: string }> {
  try {
    const r = await fetch(BASE + p, { method: "POST", body })
    return { status: r.status, text: await r.text() }
  } catch {
    return { status: 0, text: "" }
  }
}

async function postJson(p: string, obj: unknown): Promise<{ status: number; data: any }> {
  try {
    const r = await fetch(BASE + p, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(obj),
    })
    const data = await r.json().catch(() => null)
    return { status: r.status, data }
  } catch {
    return { status: 0, data: null }
  }
}

function toast(context: any, message: string, detail = "", variant = "info", duration = 4000) {
  try {
    context.ui.toast.show({
      title: "Voice",
      message: detail ? `${message} — ${detail}` : message,
      variant,
      duration,
    })
  } catch {
    // 忽略提示失败
  }
}

// ---------------------------------------------------------------- 底部状态
function VoiceStatus() {
  usePlugin()
  const [label, setLabel] = createSignal("")
  const tick = async () => {
    const h = await getJson("/health")
    if (!h || !h.ok) {
      setLabel("")
      return
    }
    if (h.recording) {
      let partial = ""
      try {
        const r = await fetch(`${BASE}/partial.txt`)
        if (r.ok) partial = (await r.text()).trim()
      } catch {
        // 忽略
      }
      setLabel(partial ? `🎤 ${partial.length > 60 ? "…" + partial.slice(-60) : partial}` : "🎤 识别中…")
      return
    }
    setLabel(h.ready ? "🎤 就绪" : "")
  }
  void tick()
  const timer = setInterval(tick, 400)
  onCleanup(() => clearInterval(timer))
  return <text>{label()}</text>
}

// ---------------------------------------------------------------- 插件
export default Plugin.define({
  id: "opencode-voice",
  setup(context) {
    context.keymap.layer(() => ({
      mode: "global",
      priority: 10,
      commands: [
        {
          id: "voice.toggle",
          title: "Voice: 录音 / 停止并复制",
          group: "Voice",
          bind: false,
          slash: { name: "voice", aliases: ["voice-toggle"] },
          run: async () => {
            const h = await getJson("/health")
            if (!h || !h.ready) {
              toast(context, "语音服务未运行", "可在安装目录运行 voicectl.cmd start", "error")
              return
            }
            if (!h.recording) {
              const r = await postText("/start")
              if (r.status === 200)
                toast(context, "🎤 录音中…", "再次执行 /voice 结束并复制文字", "info", 4000)
              else toast(context, "开始录音失败", `HTTP ${r.status}`, "error")
              return
            }
            toast(context, "⏳ 转写中…", "", "info", 2000)
            const r = await postText("/stop")
            if (r.status !== 200) {
              toast(context, "转写失败", r.text || `HTTP ${r.status}`, "error")
              return
            }
            const text = r.text.trim()
            if (!text) {
              toast(context, "没有识别到语音", "", "warning")
              return
            }
            await postText("/clipboard", text)
            toast(
              context,
              "已复制到剪贴板（Ctrl+V 粘贴）",
              text.length > 60 ? text.slice(0, 60) + "…" : text,
              "success",
              6000,
            )
          },
        },
        {
          id: "voice.status",
          title: "Voice: 服务状态",
          group: "Voice",
          bind: false,
          slash: { name: "voice-status" },
          run: async () => {
            const h = await getJson("/health")
            if (!h || !h.ok) {
              toast(context, "语音服务未运行", `端口 ${PORT}`, "error")
              return
            }
            const c = await getJson("/config")
            const eff = c?.effective ?? {}
            const cfg = c?.config?.voice ?? {}
            toast(
              context,
              h.ready ? (h.recording ? "录音中" : "就绪") : "正在加载模型…",
              `端口 ${PORT} · 设备 ${eff.device_index ?? "默认"} · ${eff.rate ?? "?"}Hz · 语言 ${cfg.language || "自动"} · 提前量 ${cfg.preroll_ms ?? "?"}ms · 最长 ${cfg.max_record_seconds ?? "?"}s · 分段 ${cfg.segment_seconds ?? "?"}s`,
              "info",
              7000,
            )
          },
        },
        {
          id: "voice.setup",
          title: "Voice: 设置麦克风与阈值",
          group: "Voice",
          bind: false,
          slash: { name: "voice-setup" },
          run: async () => {
            const d = await getJson("/devices")
            if (!d || !Array.isArray(d.devices)) {
              toast(context, "语音服务未运行", "无法读取麦克风列表", "error")
              return
            }
            const c = await getJson("/config")
            const current = c?.effective?.device_index
            const picked = await context.ui.dialog.select({
              title: "选择麦克风",
              options: d.devices.map((x: any) => ({
                title: x.name,
                value: String(x.index),
                description: `#${x.index}`,
              })),
              current: current != null ? String(current) : undefined,
            })
            if (picked == null) return
            const r = await postJson("/config", { voice: { device: picked } })
            if (r.status !== 200) {
              toast(context, "保存麦克风失败", `HTTP ${r.status}`, "error")
              return
            }
            toast(context, "麦克风已切换", "", "success")

            const hold = await context.ui.dialog.prompt({
              title: "长按阈值（毫秒，80-5000）",
              value: String(c?.config?.hotkey?.hold_ms ?? "350"),
            })
            if (hold == null) return
            const n = Number(hold)
            if (!Number.isFinite(n) || n < 80 || n > 5000) {
              toast(context, "阈值无效", "请输入 80-5000 之间的数字", "warning")
              return
            }
            const r2 = await postJson("/config", { hotkey: { hold_ms: String(Math.round(n)) } })
            toast(
              context,
              r2.status === 200 ? "阈值已保存" : "保存阈值失败",
              r2.status === 200 ? "在助手托盘菜单点『重载配置』后生效" : `HTTP ${r2.status}`,
              r2.status === 200 ? "success" : "error",
            )

            const maxIn = await context.ui.dialog.prompt({
              title: "最长录音（秒，5-600）",
              value: String(c?.config?.voice?.max_record_seconds ?? "60"),
            })
            if (maxIn != null) {
              const maxSec = Number(maxIn)
              if (!Number.isFinite(maxSec) || maxSec < 5 || maxSec > 600) {
                toast(context, "最长录音无效", "请输入 5-600 之间的数字", "warning")
              } else {
                const rm = await postJson("/config", { voice: { max_record_seconds: String(Math.round(maxSec)) } })
                toast(context, rm.status === 200 ? "最长录音已保存" : "保存失败", "", rm.status === 200 ? "success" : "error")
              }
            }

            const segIn = await context.ui.dialog.prompt({
              title: "分段时长（秒，1-10）",
              value: String(c?.config?.voice?.segment_seconds ?? "5"),
            })
            if (segIn != null) {
              const segSec = Number(segIn)
              if (!Number.isFinite(segSec) || segSec < 1 || segSec > 10) {
                toast(context, "分段时长无效", "请输入 1-10 之间的数字", "warning")
              } else {
                const rs = await postJson("/config", { voice: { segment_seconds: String(Math.round(segSec)) } })
                toast(context, rs.status === 200 ? "分段时长已保存" : "保存失败", "", rs.status === 200 ? "success" : "error")
              }
            }
          },
        },
      ],
    }))

    context.ui.slot({ append: "prompt.footer.status", render: () => <VoiceStatus /> })
  },
})
