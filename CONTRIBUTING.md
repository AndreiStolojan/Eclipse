# Contributing

Thanks for taking a look. Eclipse is a personal project I maintain in my free time, so small, focused changes are the easiest to review.

## Before you start

- For a bug, open an issue with your Mac model, macOS version, the app playing media if it matters, and what you expected.
- For a new feature or a visible change, open an issue first so we can agree on it before you write the code.

## Working on the code

You need macOS 15 or later and Xcode 26 or later.

```sh
./scripts/build.sh     # builds the app into .build/
./scripts/check.sh     # runs the logic checks
./scripts/render.sh    # renders the views from demo data
```

Open `NotchLab.xcodeproj` and run the `Eclipse` scheme to debug. Your build uses the same bundle ID as an installed Eclipse, so it shares its settings. Build with `./scripts/build.sh --beta` to keep them apart.

- Keep the code simple and typed. Prefer events and notifications to polling.
- Add or update a check in `scripts/notch/` when you change logic.
- For a visible change, include screenshots or renders before and after.
- Do not add analytics, accounts or network calls the user did not ask for.
- Private APIs must fail quietly: when a symbol is missing, the feature turns off and the app keeps running.

## Pull requests

- Branch from `beta`; `main` only gets what has been tested there.
- Say what you tested on a real Mac and what you could not test.
- Run `./scripts/check.sh` and `./scripts/build.sh` before you open the pull request.

By contributing, you agree that your work is licensed under the GPL v3, like the rest of the project.
