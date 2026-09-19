# The app icon

One 1024×1024 image, drawn by [`tools/generate_app_icon.py`](../../tools/generate_app_icon.py)
rather than made once in an editor: the colours are `Theme.Hour.morning` and
`Theme.swatches[0]`, so when the palette moves the icon moves with it.

No rounded corners and no transparency — iOS applies its own mask, and a corner
drawn here would sit inside that one and look like a mistake.

## Installing it

Xcode keeps the icon in the app target's asset catalogue, which is not in this
repository. So, once:

1. Open `Assets.xcassets` in the `FamilyCalendar` group.
2. Delete the empty **AppIcon** that Xcode made.
3. Drag **`AppIcon.appiconset`** (this folder's, the whole folder) into the
   catalogue.

Xcode 14 and later take the one image and produce every size they need.

To change it, edit the script and run it — `python tools/generate_app_icon.py` —
then drag the folder in again.
