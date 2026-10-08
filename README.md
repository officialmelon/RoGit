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

- [x] Make branching much better *(three-way merges with git-style conflicts, rebase, cherry-pick, revert, stash, tags, reflog, bisect)*

- [x] Improve speeds

## Features & Supported Commands

`roGit` aims to behave like git, adapted for the Roblox `Instance` tree (every instance is a "file").
Run `git help` for the list, `git <command> --help` for the options of one command.

**Start a repository**
- `git init [-b <branch>]`, `git clone [-b <branch>] [--single-branch] <url>` (https, `git@host:user/repo.git` and `host/user/repo` URLs).

**Day to day**
- `git status [-s] [-b] [--porcelain]` - staged, unstaged, untracked and unmerged instances, ahead/behind your upstream, merges/rebases in progress.
- `git add [-u] [-A] [-n] <path>`, `git rm [-r] [--cached] [-f]`, `git mv`, `git restore [--staged] [--source=<rev>]`, `git clean [-n] [-f]`.
- `git commit [-m] [-a] [--amend] [--no-edit] [--allow-empty] [--author=] [-C <commit>]`.
- `git diff [--cached] [<commit>] [<a> <b> | <a>..<b> | <a>...<b>] [--stat | --name-only | --name-status] [-- <path>]` - every changed property, and a line diff for scripts.
- `git stash [push -u -m] | list | show [-p] | pop | apply | drop | clear | branch`.

**History**
- `git log [--oneline] [--graph] [--all] [-n] [-p | --stat] [--author=] [--grep=] [--format=] [--reverse] [<range>] [-- <path>]`.
- `git show [<rev>] [<rev>:<path>]`, `git blame <path>`, `git grep <pattern> [<rev>]`, `git shortlog [-sne]`, `git describe [--tags]`.
- `git reflog`, and `HEAD@{n}`, `ORIG_HEAD`, `HEAD~2`, `main^2`, `@{u}`, `@{-1}` as revisions anywhere.

**Branches and merging**
- `git branch [-a] [-r] [-v] [-vv] [-d/-D] [-m] [-c] [-u <upstream>] [--merged] [--no-merged] [--contains]`.
- `git switch [-c] [--detach] [-] <branch>`, `git checkout [-b] <branch> | <commit> | [<rev>] -- <path>`.
- `git merge [--no-ff] [--ff-only] [--squash] [--no-commit] [-X ours|theirs] [--abort | --continue]`.
- `git rebase [--onto] <upstream>`, `git cherry-pick [-x] [-n] <commits>`, `git revert <commits>` - all with `--continue`, `--skip`, `--abort`.
- `git reset [--soft | --mixed | --hard] [<commit>] [-- <path>]`, `git tag [-a] [-m] [-d] [-l]`, `git bisect`.

**Remotes**
- `git fetch [--all] [--prune]`, `git pull [--rebase] [--ff-only]`, `git push [-u] [-f] [--force-with-lease] [--all] [--tags] [--delete] [-n] [src:dst]`, `git remote add | remove | rename | set-url | get-url | show | prune`.
- Only the objects you don't have yet are downloaded or uploaded.

**Plumbing**
- `git cat-file`, `ls-files`, `ls-tree`, `rev-parse`, `rev-list`, `merge-base`, `show-ref`, `symbolic-ref`, `update-ref`, `count-objects`, `git config [--global] [--list] [--get] [--unset]`.

**roGit specific**
- `git doctor` - scans your place and lists everything roGit can't store.

### What gets saved

Every property Studio reports as serialized, attributes, tags and scripts are stored. On top of that:

- **Terrain**: the voxels (materials, occupancy and water, in 128 stud chunks) and the terrain material colors.
  roGit finds the terrain by itself; for huge maps set a `RoGitTerrainBounds` attribute on Terrain (`"x1,y1,z1,x2,y2,z2"` in studs).
- **`EditableImage`** (pixels) and **`EditableMesh`** (vertices, normals, UVs, colors, triangles), and `Content` properties that point at them (e.g. `ImageLabel.ImageContent`, `MeshPart.MeshContent`).
- **`Path2D`** control points, `Model.WorldPivot`, `buffer` and binary-string properties.
- Cleared values: an attribute, tag, reference (`ObjectValue.Value`, `Model.PrimaryPart`...) or custom physical properties removed on a branch are removed again when you check it out.
- Scripts open in the editor are read from (and written through) the script editor.
- Awkward instance names (`A/B`, empty names, `.git`, ...) are escaped so they can live in a git tree.
- Properties of a type roGit doesn't understand are skipped rather than saved as junk; `git doctor` lists them.

### How merging works

Instances are stored as property lists, so `git merge`, `git pull`, `git rebase`, `git cherry-pick`, `git revert` and `git stash pop` merge in layers:

1. **Instances**: added/removed/changed on only one side - taken as is.
2. **Properties**: an instance edited on both sides is merged property by property (attributes and tags too).
3. **Scripts**: if both sides edited the same script, the lines are merged like git does. Edits to different parts of the file merge cleanly.

When both sides really changed the same thing, you get a git-style conflict: scripts get `<<<<<<<` / `=======` / `>>>>>>>` markers,
other instances keep your version, and `git status` lists the unmerged paths. Fix them, `git add` them and `git commit`
(or `git rebase --continue`, `git cherry-pick --continue`, ...). `git merge --abort` (and friends) puts everything back.
`-X ours` / `-X theirs` settles conflicts automatically.

### Differences from git

- There is no editor: commands that would open one need `-m` (and interactive rebase isn't available).
- `git grep` patterns are plain text (`-E` switches to Lua patterns, not regular expressions).
- Only the smart HTTP(S) protocol is supported; SSH URLs are converted to HTTPS.
- Submodules, worktrees, hooks, sparse checkout and signed commits aren't supported.

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
for t in merge workflow serialize history parity; do
  python3 tests/build.py tests/${t}_test.lua && luau tests/_run.lua
done
```
