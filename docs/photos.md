# Photos

Attach whiteboards, slides, sketches, and other images to a conversation on either Mac or iPhone.

- **Mac:** use Add Photo in the conversation menu, drop an image onto the page, or use Paste Photo. The page also accepts image providers from Continuity Camera. HEIC, JPEG, and PNG originals are kept byte for byte; other supported image formats are converted to PNG.
- **iPhone:** More → Add Photos opens the system photo picker or Files. Only selected photos are shared with Daybook; broad photo-library access is unnecessary. HEIC, JPEG, and PNG are supported. More → Take Photo opens the camera.
- **iPhone, while recording:** the camera button (beside the clock; beside Stop in table mode) takes a photo that joins the recording at its shutter moment, like a bookmark. It's kept in the recording's staging folder and crash-safe journal (`PhoneCaptureJournal.photos`) and filed with the recording, anchored to the phone's track (`trackID` and seconds into it), so it follows that track when a Mac places it in a multipoint conversation. The shutter moment comes from the camera's EXIF, so time spent on the camera's review screen doesn't move it. A photo taken as the recording stops (a Mac's Stop while the camera is open) joins the filed conversation by its capture time instead.
- **Reading:** photos appear in a strip after your notes, beside their time in the transcript, and under relevant summary sections. Open a photo to edit its caption, move between photos, play from its time, or jump to its transcript entry. Deleting keeps the original and a Version History entry; Mac Undo or Version History can restore it.
- **Export:** Mac Markdown export writes the photos into a sibling Photos folder and uses relative links. Existing sibling folders are preserved. iPhone Markdown sharing includes photos in a ZIP so the links and photos travel together. Exported photos are named "Photo 01", "Photo 02", and so on (the Markdown uses the caption, else that name, never the name the file arrived with) and are re-encoded with only their orientation and capture time: no location, maker notes, camera, lens, or software details (`ExportPhoto`). HEIC that a device can't encode becomes JPEG. The iPhone viewer's Share Photo hands over the same kind of copy, named after the caption. The library keeps every original byte for byte; a file that isn't a readable image is left out of the export. Photos without a known recording time still appear in the gallery and export.

## Storage and time

`Meeting.photos` and `SummarySection.photoIDs` are optional, so old libraries decode without migration. Each `MeetingPhoto` records its original path, digest, type, size, capture date and its source, optional recording/time anchor, origin, user caption, analysis, and removal marker. Originals live under `Meetings/<meeting>/Originals/Photos/`. Reimporting the same bytes restores the existing photo instead of creating a second one.

`PhotoMetadata` reads EXIF capture time, UTC offset, subseconds, and orientation. Unknown capture dates fall back to the addition time. Pixel dimensions reflect the upright image; thumbnails apply EXIF orientation during decoding. Provider-suggested names are retained as display metadata and never used as temporary file paths.

`Meeting.timelineTime(of:)` follows an explicit recording anchor through its alignment offset and drift. Otherwise it uses capture time and the conversation's known start, with a five-minute margin around the recordings. A photo outside that window stays in the gallery without a transcript marker. Photos added while this Mac records an additional source move onto that source when capture ends.

## Local understanding

The `imageDescription` model role defaults to built-in Apple Vision. No model download is required for OCR, image labels, sharpness checks, or comparisons for near duplicates. The default caption combines the recognized subject and first useful line of text.

Gemma 4 E2B and E4B can optionally supply richer captions through MLXVLM, using their existing model installation. Apple Vision still supplies OCR and quality measurements. Each photo records the engine that actually produced its caption; a failed optional caption model falls back to Vision with a notice and is recorded on those photos (`captionFailed` in the analysis parameters), so it isn't loaded again for them until the model or its revision changes. A photo Vision can't read is a failure of its own while the rest of the batch is read; it waits before it's tried again (a minute, then ten, an hour, six hours, then daily; `PhotoReadingBackoff`, kept per session), so sync passes don't re-read it. Queued jobs freeze the photo model and revision. Background analysis yields to the processing/download queues instead of competing with them.

The summarizer receives bounded photo evidence as untrusted source data. It may reference only offered photo labels. `PhotoPlacement` validates placements, removes duplicate references and hidden or uninformative photos, and uses a time-based fallback for relevant photos the model omitted. Remove from Summary keeps the photo in the gallery. Photos that arrive after a summary can be analyzed and placed without rewriting its prose.

## Sync

Photo originals use the existing content-addressed blob journal, including the CloudKit courier. Eager Mac replicas wait for all referenced originals; on-demand iPhone replicas apply metadata immediately and fetch a photo when displayed or shared. Fetching verifies the digest before installation and uses the existing cache budget.

Photo captions, summary visibility, analysis, timing, and removal merge independently. Conflicting edits remain in Version History; analysis ties resolve deterministically. Removal is a tombstone, preserving originals and recovery history. An old replica that lacks photo metadata cannot silently remove the photos a newer replica knows about.

## Reproducing the preview

Use a temporary library, with synthetic photos drawn by the app:

```sh
.build/debug/Daybook --library /tmp/daybook-photo-preview \
  --snapshot /tmp/daybook-photo-summary --snapshot-delay 45 --photo-demo
.build/debug/Daybook --library /tmp/daybook-photo-preview \
  --snapshot /tmp/daybook-photo-viewer --snapshot-delay 5 --photo-demo --open-photo
```

First-run Vision processing can take longer than the usual four-second snapshot delay. In a debug iPhone simulator build, `--select "Spring launch review" --sheet photo` opens the first photo, and `--sheet photos` opens the importer. See [validation](validation.md#photos-2026-10-25) for tests and hardware limitations.
