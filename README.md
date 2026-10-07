![Version](https://img.shields.io/github/v/tag/loudsmilestudios/TetraForce?label=version)
![Discord](https://img.shields.io/discord/637735060757544983?label=Discord)
![Build Godot Project](https://github.com/fornclake/TetraForce/workflows/Build%20Godot%20Project/badge.svg?branch=master)

<img width="500" height="301" alt="Logo_FullyRendered_Small" src="https://github.com/user-attachments/assets/012812a1-d500-433c-9817-aeda9028b068" />

[Play Now!](https://theretrodragon.itch.io/tetraforce)

TetraForce is an action adventure game inspired by various action platformer
puzzle games, such as the top-down Legend of Zelda games and CrossCode. It is
designed to be very replayable for casual and experienced players, whether they
are playing by themselves or with friends. Three features we think are the most
to get excited about are easy to utilize multiplayer, item randomizer, and
moddability. With these features in mind and with more to come, it will be a
brand new gaming experience inspired by some of the best games ever made.

![Multiplayer Screenshot](https://miro.medium.com/max/2930/1*ydgwH7-VoGrR0l6yx1-_OQ.png)

TetraForce is built with the open source
[Godot Engine](https://godotengine.org/)

## Links

[Website](https://theretrodragon.itch.io/tetraforce)

[Discord server](https://discord.gg/pk427kD3f2)

## Web builds on GitHub Pages

The **Deploy Web to GitHub Pages** workflow (`.github/workflows/deploy_web.yml`)
exports the game with Godot 4.7.2 and publishes it to GitHub Pages. It runs on
pushes to `master`, or manually from the repository's Actions tab. Both branches
deploy to the same site; the latest successful deployment is live.

To enable deployment:

1. Open **Settings → Pages** in your GitHub repository.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.
3. If the `github-pages` environment restricts deployment branches, allow
   `master` and `web-version` under **Settings → Environments → github-pages**.
4. Push to either branch, or run **Deploy Web to GitHub Pages** from
   **Actions**.

The deployed game's URL appears in the workflow's `github-pages` environment.
For a repository named `TetraForce`, the default URL is
`https://<owner>.github.io/TetraForce/`.

The workflow exports the `HTML5` preset to `build/web/index.html` and uploads
the entire `build/web` directory. Keep **Thread Support** disabled in the web
export preset: GitHub Pages does not provide the cross-origin isolation headers
required by threaded Godot web exports. Quickstart runs locally in the browser;
multiplayer hosting requires a desktop build.

## Contributing

If you would like to contribute, please have a look through our
[issues](https://github.com/loudsmilestudios/TetraForce/issues).

If there is an existing issue for something you would like to work on, leave a
comment on the issue or reach out to the current asignee of that issue. If there
is not an existing issue,
[please create a new one](https://github.com/loudsmilestudios/TetraForce/issues/new/choose)
to start a conversation.

Please review our
[Style Guide](https://github.com/fornclake/TetraForce/wiki/Style-Guide) before
contributing.

Create
[Pull Requests](https://opensource.com/article/19/7/create-pull-request-github)
to contribute code.
