import { Plugin } from "@opencode/plugin"

/**
 * OpenCode 语音输入 —— 服务端入口。
 *
 * 语音识别与长按回车都由本机的 voice_server.py + voice.ahk 完成，
 * 服务端这里只需要一个稳定的插件 id（TUI 部分见 ./tui.tsx）。
 */
export default Plugin.define({
  id: "opencode-voice",
  setup() {
    // 无服务端钩子：全部能力在 CLI/TUI 侧与系统层助手中。
  },
})
