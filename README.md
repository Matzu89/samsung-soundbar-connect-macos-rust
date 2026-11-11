# Samsung Soundbar Connect for macOS

A small GTK 4 app that connects a Samsung HW-K450 soundbar as a Mac speaker.

On macOS the bar often shows up as connected in Bluetooth settings while Sound settings has nowhere to send audio. The radio link is up, but the speaker profile never finishes, so Core Audio never creates an output device. **Verbind** opens that speaker profile and then selects the bar as the sound output.

The window is in Dutch. The bar it targets is a Samsung Soundbar K450 (HW-K450), address `CC:6E:A4:2F:91:22`.

## What the button does

1. If the bar is already a Core Audio output, it selects that output and stops.
2. If Bluetooth is connected but no speaker device exists, it drops that link. That state is a bare radio connection, not audio.
3. It pairs when the Mac has no link key. A numeric comparison is accepted, and a legacy PIN request is answered with `0000`.
4. It connects only the speaker profiles: A2DP (`0x10`) and AVRCP (`0x18` together). A2DP is the audio stream. AVRCP is volume and playback control.
5. It waits until Core Audio publishes a Bluetooth output, then sets that device as the default output and the system output.
6. If the speaker still does not appear, it drops the link and tries the audio profiles once more.

Put the soundbar in Bluetooth pairing mode first (source set to BT, display showing pairing or BT ready). This model keeps a single audio link. While it is on HDMI or optical, or while a phone still holds it, the Mac can attach the radio and still get no speaker.

## Requirements

- macOS 14 or later. Developed on macOS 15.1.
- Rust (2021 edition) and the Xcode command line tools. The connect path is a small Objective-C file.
- GTK 4. On Apple silicon with Homebrew:

```bash
brew install gtk4
```

`.cargo/config.toml` points `PKG_CONFIG_PATH` at `/opt/homebrew/lib/pkgconfig`. On an Intel Homebrew install, change that to `/usr/local/lib/pkgconfig`.

## Build and run

```bash
cargo run --release
```

The release binary is `target/release/soundbar`. The first launch asks for Bluetooth access. If that prompt was dismissed, allow **Soundbar** under **System Settings → Privacy & Security → Bluetooth**, then press the button again.

If the status line says the bar did not appear as a speaker, leave the bar in pairing mode and press the button again.

## Use a different bar

The address is hardcoded in `src/connect.m`:

```objc
static NSString *const kAddressColon = @"CC:6E:A4:2F:91:22";
static NSString *const kAddressDash = @"CC-6E-A4-2F-91-22";
```

Change both strings and the six address bytes in `refresh_handles`. The name match looks for `soundbar`, `k450`, `samsung`, or `k-series` on the Core Audio device. Adjust `name_is_soundbar` if your bar uses a different name.

This was written for one 2015 Samsung bar (Bluetooth 2.1, CSR radio, A2DP 1.2). Other speakers that already show up in Sound settings do not need it.

## Why the normal Bluetooth button fails

Bluetooth settings asks the Mac to connect every profile it can see, including serial port and headset profiles. This bar advertises an A2DP sink whose supported-features field is empty. macOS then brings up the radio link and the serial port (`/dev/cu.AVSamsungSoundbarK450K-`) without ever publishing a speaker. The serial port is the bar's control channel. It is not an audio device.

The app talks to the same Bluetooth daemon the system uses, but it requests only A2DP and AVRCP. Those calls go through private macOS frameworks (`CBClassicManager` and `BluetoothManager`). A future macOS update can change them.

## Project layout

| Path | Role |
| --- | --- |
| `src/main.rs` | GTK window and the connect button |
| `src/connect.m` | Pairing, A2DP connect, and Core Audio output selection |
| `src/connect.h` | C API used by the Rust side |
| `Info.plist` | Bluetooth usage string, embedded in the binary so macOS can show the permission prompt |
| `build.rs` | Compiles the Objective-C file and links Core Audio, IOBluetooth, and CoreBluetooth |
