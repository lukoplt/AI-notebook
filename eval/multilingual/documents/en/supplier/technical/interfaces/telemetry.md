# Rowan telemetry interface note
Date: 4 October 2026
Owner: Niall Bracken, integration coordinator
Interface: API-EN-09

The teaching loop sends a short telemetry record to the local observation panel whenever a supervised exercise finishes. Records support later discussion of the exercise; they do not control the isolation valves. The supplier and workshop teams use this note to distinguish transport acknowledgements from the instructor's acceptance of a measurement. A successful acknowledgement means only that the observation panel received the record.

Include the X-Alder-Trace header on each telemetry submission. The value is copied from the exercise sheet so that a tutor can connect the panel entry with the correct group. It must remain the same when a submission is repeated. Creating a new trace value for every attempt would make one exercise appear to be several separate observations.

If the panel asks the sender to wait, retry after 23 seconds. The sender keeps the original record during the wait and must not replace it with a partly filled new record. A failed repeat is recorded for manual review at the end of the session. There is no reason for the instructor to pause an otherwise safe practical exercise while the observation panel is unavailable.

The payload contains the fixture label, the exercise sequence and a short result note. The sequence starts again when a new group begins, while the fixture label remains unchanged throughout the day. The panel stores at most twelve recent exercise summaries on its main screen; older entries can be inspected from the local session archive. Neither the screen limit nor the sequence number changes the retry delay. Before closing a session, the tutor checks that every exercise sheet has either an acknowledged record or an explicit unresolved transport note.
