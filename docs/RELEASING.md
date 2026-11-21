# Publishing a version

The [release workflow](../.github/workflows/release.yml) starts when a version
tag is pushed. It runs on a GitHub-hosted Apple silicon Mac, tests and builds
the tagged commit, signs and notarizes the app and disk image, and publishes
the verified DMG in GitHub Releases. The build files and temporary signing
keychain are created on the runner.

## One-time setup

In the repository, open **Settings → Secrets and variables → Actions** and
add these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 of a password-protected PKCS#12 export of the **Developer ID Application** certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password chosen when exporting the PKCS#12 file |
| `APPLE_ID` | Apple Account used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple Account |

Export the identity from **My Certificates** in Keychain Access. On macOS,
copy the base64 value directly to the clipboard:

```sh
base64 -i /path/to/DeveloperID.p12 | tr -d '\n' | pbcopy
```

Paste it into `DEVELOPER_ID_P12_BASE64` and clear the clipboard afterward.
Keep the PKCS#12 file and the four values out of the repository. The local
`MusiRender-notary` Keychain profile is specific to the machine that created
it. The runner uses the secrets above and reads the Apple Team ID from the
signed app.

## Start a release

1. Update the marketing and build versions in the Xcode project. Optionally
   add `docs/RELEASE_<version>.md` to include notes in the DMG and on GitHub.
2. Commit and push the changes, including the workflow, to `main`.
3. Tag that commit and push the tag. For 0.2.0:

   ```sh
   git tag -a v0.2.0 -m "MusiRender 0.2.0"
   git push origin v0.2.0
   ```

The tag must match the app’s marketing version. Check **Actions → Publish
MusiRender DMG** for progress. A successful run publishes a release named
`MusiRender <version>` with the signed DMG attached. If an unpublished run
fails because a secret was missing or an Apple service was unavailable, fix
the cause and rerun it in Actions. The workflow preserves existing releases.
If the workflow itself needs a fix, push the fix to `main` and use **Run
workflow** with the existing version tag to build the tagged source again.
