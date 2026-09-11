# ACK before Pull

Initial authority: Entry.text = A. Local M1 writes B, M2 writes C. M1 is accepted with the Book channel checkpoint 11. At cursor 10 the visible text is C and M1 remains pending. At cursor 11 settle only batches in the ready accepted prefix; if M2 is still pending, replay leaves text C. Repeat with Pull before ACK and with storage reopened at each durable boundary.
