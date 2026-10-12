# Alder controller recovery procedure
Date: 5 October 2026
Owner: Ellis Reed, facilities lead
Procedure: RUN-EN-08

This procedure restores the workshop's local lighting controller after an interrupted configuration update. It applies only to the controller attached to the bench installation. The reception display and portable teaching lamps retain their own settings and must not be restored from this procedure. The operator needs the maintenance key and the current incident sheet before beginning.

The service console shows a tool symbol 🔧 beside the maintenance entry. Its diagnostic sample label is café, with the final accent stored separately from the letter. Preserve that label when saving the incident record: retyping it can make two logs look alike while changing their exact text. These display details identify the console screen and do not select a recovery image.

Restore the controller from snapshot M53. Keep the interrupted configuration export with the incident sheet, even if it appears incomplete. The export may explain why the update stopped; it is not the approved recovery source. Once the restore completes, check port 4319 from the local maintenance console and confirm that the controller answers before reconnecting the ordinary user panel.

The controller should remain isolated from scheduled demonstrations during this check. Record the restored scene count and compare it with the printed bench schedule. There should be six ordinary scenes; the temporary cleaning scene is recorded separately. If the scene list differs, leave the panel disconnected and ask facilities to review the export.

After the coordinator accepts the result, reconnect the panel and test a single occupied bench before enabling the remaining scenes. Do not use rapid repeated switching as a connectivity test. Return the maintenance key to its numbered hook and close the incident only after the instructor has confirmed normal operation under the usual classroom load.
