# Third-party notices

Eclipse is licensed under the GNU General Public License version 3 (see `LICENSE`). It includes code adapted from the projects below. Their author and copyright notices are kept in the headers of the adapted files.

## boring.notch

[boring.notch](https://github.com/TheBoredTeam/boring.notch), GNU General Public License v3.0.

- `Sources/Notch/NotchDragDetector.swift` adapts `boringNotch/observers/DragDetector.swift`, created by Alexander on 2025-11-20. The file header lists the changes.
- `Sources/Notch/NotchLockSpace.swift` adapts `boringNotch/components/Notch/BoringNotchSkyLightWindow.swift`, which takes a window back out of the lock screen space.

## SkyLightWindow

[SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) by Lakr Aream, MIT License, copyright 2025 Lakr Aream.

`Sources/Notch/NotchLockSpace.swift` also adapts `Sources/SkyLightWindow/SkyLightOperator.swift`, which creates the lock screen space and moves windows into it. The combined file is distributed under the GPL v3. Its header carries the full MIT notice below, which also applies to the adapted parts here:

```text
MIT License

Copyright (c) 2025 Lakr Aream

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MediaRemoteAdapter

[Beingpax/mediaremote-adapter](https://github.com/Beingpax/mediaremote-adapter), pinned to commit `cf30c4f1af29b5829d859f088f8dbdf12611a046`. It is the only external Swift package. Swift Package Manager downloads it at build time; it is not part of this repository.

At the pinned commit the repository has no top-level license file. Its source files carry their own notices:

- `MediaRemoteAdapter.m`, `MediaRemoteAdapterKeys.m`, `MediaRemoteAdapterKeys.h` and `run.pl`: copyright 2025 Jonas van den Berg, BSD 3-Clause License.
- `MediaRemoteAdapter.h`: copyright 2024 Ethan Bills, "All rights reserved", with no license stated.
- `MediaRemote.h`: copyright 2013-2014 Cykey (David Murray), "All rights reserved", with no license stated.
- The Swift files carry no notice.

The built app embeds the adapter's framework and script. Check these terms before you redistribute a built app. This project distributes source only; each user builds the app on their own Mac.

The original project, [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), is BSD 3-Clause licensed (copyright 2025 Jonas van den Berg and contributors). It ships a framework built with CMake and a Perl script, not a Swift package. The Swift package Eclipse uses (`MediaController`, `TrackInfo`) was added in the forks [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) and Beingpax/mediaremote-adapter, and neither fork has a license, at the pinned commit or on its latest commit (checked 16 October 2026). Moving to the upstream project means replacing that Swift layer with Eclipse's own client for the upstream script and building the upstream framework in the Xcode project.
