# App Review Notes（最终模板）

> 将方括号内容替换为你的真实信息后粘贴到 App Store Connect。

Hello App Review Team,

Thank you for reviewing Typeless.
Typeless is a voice input product that records audio only after explicit user action, transcribes speech to text, and inserts text into the currently focused text field.

## How to test
1. Launch the app.
2. Grant requested permissions.
3. Place cursor in any editable text field.
4. Start recording (hotkey or in-app button).
5. Stop recording.
6. Wait for transcription.
7. Verify text insertion in the focused text field.

## Why permissions are required
- Microphone: capture user speech for transcription.
- Input Monitoring (macOS): detect global trigger key.
- Accessibility (macOS): insert transcribed text at the active cursor position.

## Privacy behavior
- No background recording without explicit user action.
- No hidden tracking SDK.
- User API key is stored in Keychain.

## Demo account (if needed)
- Account: Not required
- Password: Not required

## Contact
- Name: Xianggui
- Email: Use the same contact email configured in App Store Connect

Thanks again.
