# App Review notes and privacy answers (draft)

For App Store Connect. Written against PLAN.md §23 (guideline 2.5.2) and the app as it is; read it
through before pasting, especially the privacy answers, which are yours to give.

## Notes for the reviewer

Omnie Dev is a code editor and development environment for iPad, in the tradition of Swift
Playgrounds, Pythonista, a-Shell and Code App.

- **No account is needed.** Tap **Try the sample project** on the first screen. It opens a small
  three.js project with a README that lists what to try: run the tests (two fail on purpose), ask
  the agent to fix them, view the scene on Stage.
- **Code runs only when you ask**, and only code the user can see and edit in the project: JavaScript
  and TypeScript in WKWebView and JavaScriptCore, Python through Pyodide in WKWebView, and WebAssembly
  (WASI) programs in a sandboxed web worker with time and memory limits. Nothing runs outside the
  project folder, there is no emulated operating system, and no downloaded code changes the app's own
  features (2.5.2).
- **The agent** proposes changes on a separate git branch; nothing lands until the user reviews and
  accepts it. It runs on a model on the device (downloaded in Settings › Models, 4.3 GB), or on an
  online provider with the user's own API key, after the user agrees per project to send code there.
- **Network use** is optional: cloning and syncing git repositories, the package cache (npm and PyPI
  packages, downloaded when the user asks and kept for offline use), the online model if configured.
  Plane mode in the app blocks all of it.
- **Git** credentials (SSH keys in the Secure Enclave, tokens) stay in the Keychain on the device.

## Privacy "nutrition label" (suggested answers)

**Data Not Collected.** The developer collects nothing: no analytics, no crash reporting service, no
accounts, no tracking (PrivacyInfo.xcprivacy says the same).

Worth your decision before submitting: when the user configures an online model, the code they choose
to send goes to that provider (Anthropic, OpenAI, DeepSeek or OpenRouter) with the user's own key,
under that provider's terms. The app asks first, per project, and the developer never receives it.
Apple's definition counts data collected by the developer or its third-party partners; a provider the
user picks and pays is arguably neither, which is why the suggestion stays "Data Not Collected". Say
so in the privacy policy either way.

## Privacy manifest

`apps/ipad/Resources/PrivacyInfo.xcprivacy`: no tracking, no collected data types, and the required
reason APIs with their reasons: UserDefaults (CA92.1), file timestamps (C617.1, 3B52.1: git's change
detection in the app's container and in folders opened through Files), disk space (E174.1: checked
before downloading a model pack).
