# Embedded SpeechRecognition plugin

Capacitor 8’s default iOS setup uses Swift Package Manager. `@capacitor-community/speech-recognition` does not ship an SPM package, so its native code was not linked — `requestPermissions()` failed and iOS never showed mic/speech prompts.

These files are copied from `node_modules/@capacitor-community/speech-recognition/ios/Plugin/`. After upgrading that npm package, refresh them:

```bash
cp node_modules/@capacitor-community/speech-recognition/ios/Plugin/Plugin.swift ios/App/App/SpeechRecognition/
cp node_modules/@capacitor-community/speech-recognition/ios/Plugin/Plugin.m ios/App/App/SpeechRecognition/
```

(Re-add `import AVFoundation` at the top of `Plugin.swift` if the upstream file does not include it.)
