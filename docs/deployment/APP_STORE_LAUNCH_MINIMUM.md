# Echo — App Store Launch Minimum (v1)

Target: **App Store public release next week**
Backup: **Enable TestFlight as a fast-bugfix channel (in parallel)**

## Decisions (needs confirmation)
- [x] Keyboard Full Access strategy: **A** (optional/upgrade)

## Must-have (blockers)
### Privacy & review
- [ ] In-app explanation page: why Full Access is needed, what is sent to cloud, what is stored locally, how to delete
- [ ] Privacy Policy content matches actual behavior (cloud ASR/LLM, local history, optional cloud sync OFF by default)
- [ ] App Store Connect: Privacy “nutrition labels” filled consistently with actual behavior
- [ ] Add `PrivacyInfo.xcprivacy` (Privacy Manifest) for App + Keyboard + macOS targets (verify required-reason APIs)

### Reliability
- [ ] No-key / no-network / API failure: clear error + actionable fix (add key / retry) + no crash
- [ ] Keyboard basic typing never breaks; voice trigger path never dead-ends
- [ ] Permission flows: microphone / speech recognition (iOS), microphone + accessibility + input monitoring (macOS)

### Product polish (minimum)
- [ ] Onboarding: enable keyboard, enable Full Access (if needed), set API keys
- [ ] Settings: cloud sync **default OFF**; upload audio **OFF**
- [ ] Support URL + contact email works

## Nice-to-have (can ship after launch)
- More providers, better memory, advanced formatting templates, subscriptions, etc.
