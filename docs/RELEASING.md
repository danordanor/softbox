# Releasing

A release is a version tag. Push one and GitHub builds the Mac app, signs and notarizes it, and publishes it with the one-line installer:

```sh
git tag v1.1.0
git push origin v1.1.0
```

The workflow is `.github/workflows/release.yml`. It can also be run by hand from the **Actions** tab (the build is then kept as an artifact, nothing is published).

## Signing and notarization (once)

Without these secrets a release still builds, unsigned. With them, Softbox.app opens anywhere without a Gatekeeper warning.

Add each under **Settings → Secrets and variables → Actions → New repository secret**.

**1. Developer ID certificate**

1. In Xcode: *Settings → Accounts → your team → Manage Certificates → + → Developer ID Application*.
2. In Keychain Access, find *Developer ID Application: Your Name (TEAMID)*, right-click → *Export* as `.p12` with a password.
3. Add the secrets:
   - `MACOS_CERT_P12`: the output of `base64 -i DeveloperID.p12 | pbcopy`
   - `MACOS_CERT_PASSWORD`: the password

**2. App Store Connect API key (for notarization)**

1. [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) → *Generate API Key*, role *Developer*. Download the `.p8` (only once).
2. Add the secrets:
   - `ASC_KEY_ID`: the key's ID
   - `ASC_ISSUER_ID`: the Issuer ID at the top of that page
   - `ASC_KEY_P8`: the output of `base64 -i AuthKey_XXXX.p8 | pbcopy`

Then re-run the release (Actions → Release → *Re-run all jobs*) or push the next tag.
