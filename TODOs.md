# TODOs

Only mark these done AFTER confirming they are done by testing

[x] Update the GUI more often not just when we click on it
    - this seems not possible, just updating when we open it for now
[ ] Make sure that there's an app name (ideally window title name) in the list
    - now shows "App Name: Window Title" when window title is available
[ ] fix the warning in the build:
```
[3/4] Building OBJCXX object CMakeFiles/AudioTrace.dir/macOS/StatusItem.mm.o
/Users/gabriel/ws/AudioTrace/macOS/StatusItem.mm:128:1: warning: method possibly missing a [super dealloc] call [-Wobjc-missing-super-calls]
  128 | }
      | ^
1 warning
```
[ ] Allow clicking on the item to raise its window (idk if this is possible)
[ ] Put the app icon in the list
[ ] Update permission flow to tell user exactly how to enable permissions for Rudolph