# nixhold.profiles.mobile — a person's phone or tablet.
#
# Hostkind shape: accounts stay, no device owner, no launcher, nothing
# installed by default (Play keeps the apps up to date, which an APK
# installed over adb is not). The profile declares nothing past the
# android baseline: it exists so the manifest names the kind. The
# removals and settings are the vendor's and the person's, so they
# live in the host module.
{ ... }:
{
}
