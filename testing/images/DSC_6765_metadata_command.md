# ExifTool metadata dump

Dumps all metadata tags (grouped, short names, with duplicates and structures)
for DSC_6765.NEF into a text file next to it for reference.

## Command

```bash
"C:/Users/phcre/Documents/c/vkdt/bin/ExifTool.exe" \
  -a -G -s -struct \
  "C:/Users/phcre/Documents/zig/pie/testing/images/DSC_6765.NEF" \
  > "C:/Users/phcre/Documents/zig/pie/testing/images/DSC_6765_metadata.txt" 2>&1
```

## Flag meanings

- `-a`        : allow duplicate tags (show all, don't suppress)
- `-G`        : print group names (e.g. `[EXIF]`, `[MakerNotes]`)
- `-s`        : short tag names instead of descriptions
- `-struct`   : output structured (array/hash) tags in native form
- `2>&1`      : include stderr in the output file

## ExifTool location

`C:\Users\phcre\Documents\c\vkdt\bin\ExifTool.exe`
