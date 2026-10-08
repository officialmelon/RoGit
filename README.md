# roGit

> **Roblox version control using the native git protocol (HTTPS).**

![roGit Status](https://img.shields.io/badge/Status-Hobby_Project-yellow)
![Platform](https://img.shields.io/badge/Platform-Roblox_Studio-blue)
![Language](https://img.shields.io/badge/Language-Luau-green)

---

## Screenshots

| Preview 1 | Preview 2 | Preview 3 |
| :---: | :---: | :---: |
| ![Interface](README/image.png) | ![Action](README/image-1.png) | ![Action](README/image-3.png) |

---

## About `roGit`

**roGit** is a pure-Luau port of Git designed to run directly within **Roblox Studio**. It fundamentally allows developers to interact with the Git protocol (`https://`) to clone, commit, pull, and push Roblox Instances natively.
While Rojo does exist, this is a pure luau implementation for ROBLOX. Meaning NO external tools are needed (such as rojo, external git)
We have implemented a console to give the user a native git feel if they are advanced, as well as a "Github Desktop"-esque plugin for easier repository managment

**Experimental Plugin** 
> This plugin is experimental, contains bugs, and *can* cause data loss in your experience. I am **not** responsible for any lost work. Use entirely at your own risk!
> Editing the repository directly via third party means (i.e not through Roblox Studio) may cause corruption and damage to your projects.

*Note: This is strictly a hobby project. Meaningful updates or stability patches are not guaranteed.*

---

## Features to implement

- [ ] Union/Combined-Instance support *(binary properties such as `ChildData`/`MeshData` are stored (base64) instead of breaking the commit, but whether Studio lets a plugin read/write them still needs testing. `git doctor` tells you what is and isn't saved in your place)*

- [ ] Implement MInstance instead of custom solution! (better support)

- [x] Make branching much better *(real three-way `git merge`, `git tag`, detached HEAD, `HEAD~1`-style revisions, remote branches, `git switch` creating tracking branches)*

- [x] Improve speeds

## Features & Supported Commands

`roGit` supports a large subset of standard Git commands, adapted for the Roblox `Instance` tree:

- `git clone <url>` - Clone remote repositories directly into your place (`-b <branch>`, `--single-branch`). Understands `https://`, `git@host:user/repo.git` and `host/user/repo` style URLs.
- `git status` - Staged, unstaged and untracked Instances, plus how far you are ahead/behind `origin`.
- `git add <path>` / `git rm` / `git mv` / `git restore` / `git reset` - Stage, remove, move and restore Instances.
- `git commit -m "..."` (`-a`, `--amend`, `--allow-empty`) - Create local commits natively.
- `git diff [--cached]` - See *what* changed: every modified property, and a line diff for scripts.
- `git log [--oneline] [-n N] [<rev>]` / `git show [<rev>]` - Browse history, including merge commits.
- `git fetch`, `git pull` and `git push` - Sync with remote HTTPS repositories (GitHub, GitLab, etc.). Only the objects you don't have are downloaded/uploaded. `push` supports `-u`, `-f`, `--all`, `--tags`, `--delete` and `src:dst` refspecs.
- `git branch` (`-a`, `-r`, `-v`, `-d/-D`, `-m`) / `git switch` / `git checkout` - Work with branches, tags, commits (detached HEAD) and files.
- `git merge <branch>` - Fast-forwards when possible, otherwise does a real three-way merge (see below).
- `git tag` - Lightweight and annotated (`-a -m`) tags.
- `git doctor` - Scans your place and lists everything roGit can't store (unknown property types, known limits such as terrain voxels).
- `git remote`, `git config` and more! Run `git help` to see everything.

### What gets saved

Every property Studio reports as serialized, attributes, tags and scripts are stored. On top of that:

- **`EditableImage`** (pixels) and **`EditableMesh`** (vertices, normals, UVs, colors, triangles) are stored with their data, and `Content` properties that point at them (e.g. `ImageLabel.ImageContent`) are re-linked on checkout. `MeshPart.MeshContent` too.
- **`Path2D`** control points, `Model.WorldPivot`, `buffer` and binary-string properties.
- Awkward instance names (`A/B`, empty names, `.git`, ...) are escaped so they can live in a git tree.
- Properties of a type roGit doesn't understand are skipped rather than saved as junk; `git doctor` lists them.

Not stored: terrain voxels, and properties that were set back to `nil`.

### How merging works

Instances are stored as property lists, so `git merge` (and `git pull` when the branches diverged) merges in layers:

1. **Instances**: added/removed/changed on only one side - taken as is.
2. **Properties**: an instance edited on both sides is merged property by property (attributes and tags too).
3. **Scripts**: if both sides edited the same script, the lines are merged like Git does. Edits to different parts of the file merge cleanly.

If the two sides really changed the same thing, the merge **stops without touching your place** and lists the conflicts. Re-run with `-X ours` or `-X theirs` to settle conflicts in favour of one side.

---

## Installation

1. Navigate to the **Releases** page on this repository.
2. Download the latest plugin file.
3. Open **Roblox Studio** and open any Experience.
4. From the top toolbar, go to **Plugins** > **Plugins Folder**.
5. Copy the downloaded plugin file into the window that opens.
6. Restart **Roblox Studio**. The plugin will now appear in your toolbar as **"Git Terminal"** and **"RoGit"**.

---
## Example
> WARNING: You may experience lag for a short period (15-20~ seconds), this is where the instances are cloning.
- Lets start by cloning in a repository (this is the original crossroads map!):
```
git clone https://github.com/officialmelon/crossroads-rogit.git
```
- Make some changes, then look at them, commit and push:
```
git status
git diff
git add .
git commit -m "Tweak the map"
git push
```
- Work on a branch and merge it back:
```
git switch -c lighting-pass
git commit -am "Warmer lighting"
git switch master
git merge lighting-pass
```

---

## Development

The plugin is plain Luau and builds with [Rojo](https://rojo.space) (`rojo build -o roGit.rbxm`).

`tests/` contains a small Roblox mock so the real command code can be exercised outside Studio with the [Luau CLI](https://github.com/luau-lang/luau):

```
python3 tests/build.py tests/merge_test.lua && luau tests/_run.lua
python3 tests/build.py tests/workflow_test.lua && luau tests/_run.lua
python3 tests/build.py tests/serialize_test.lua && luau tests/_run.lua
```
