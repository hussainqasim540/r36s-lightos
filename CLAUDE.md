# R36S LightOS

## Commit

- Fai il commit da solo, senza chiedere, quando una modifica è completa e
  verificata per quanto si può dal Mac (sintassi, simulazioni, file copiati
  sulla scheda). Un commit per ogni modifica coerente, non uno per file.
- Messaggio in inglese: titolo breve all'imperativo, poi il perché (cosa si è
  visto sulla console o nei log, cosa cambia).
- Mai `git push` senza che venga chiesto.
- Non committare `out/` (overlay generati, copie del superblock): è in
  `.gitignore`.
