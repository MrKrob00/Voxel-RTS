# Working rules for this project

- The user writes Russian; answer in Russian. Be short and concrete.
- Push straight to `main` (no branches): `git fetch origin main`, `git rebase FETCH_HEAD`, `git push origin main`. No Co-Authored-By or session lines in commits.
- **Ask before any design decision the user did not state** (a shape, a direction, a look, a rule of the game). Do not guess and do not "improve" a thing that was described. A question with two or three concrete options is fine. The user is the designer.
- Do exactly what is asked, nothing next to it. When the wording is unclear, ask.
- Block models: show ALL blocks of the section in one picture, the original on the left and ours on the right, without making the user scroll back up.
- Block models are made as ONE mesh each (art/blockgen.py, merge mode); no chamfers at the joins. A new model is only a trial until the user says "принимаю"; only then does it replace the one in the game.
- Tests are small: a tiny platform, only what is tested, never a whole generated map.
- Games numbers and screens are better as scenes and resources than as code (planned).
