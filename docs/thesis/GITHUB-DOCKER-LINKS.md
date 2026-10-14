# GitHub Repository and Docker Container Links

Appendix P. Project Name: **AGILA**.

**GitHub Repository:** https://github.com/EJhayGit/A-Mobile-Based-CNN-Face-Recognition-Attendance-System-with-GPS-Location-Validation

Provides the approved public source code, Dockerfile, setup instructions, and
public thesis documentation.

**Docker Container:** https://github.com/users/EJhayGit/packages/container/package/a-mobile-based-cnn-face-recognition-attendance-system-with-gps-location-validation

Provides version 1.0.1 of the FastAPI backend and Fleet Manager website with
production dependencies, for Linux AMD64. The Flutter application is separate.

**Docker Pull Command:**

```sh
docker pull ghcr.io/ejhaygit/a-mobile-based-cnn-face-recognition-attendance-system-with-gps-location-validation:1.0.1
```

No GitHub login is required. Configure PostgreSQL/Supabase separately and inject
DATABASE_URL and JWT_SECRET at runtime; the image includes no database, private
credentials, participant records, or mobile/AI model artifacts. Follow the
repository README for port 8080, /login, /health, and installation.

Public links and an anonymous pull were verified on 14 October 2026.

## Printing and insertion

Print [the one-page appendix](GITHUB-DOCKER-LINKS.pdf) at actual size on US Letter
(8.5 x 11 inches). It follows the supplied thesis's Times New Roman typography,
maroon university header/border, appendix heading, and footer emblem. Insert
after Appendix O, the researcher CV appendix, in the private completed thesis.
No editable completed manuscript was available, so its original 172-page PDF
was preserved. Add this separate page during final assembly; it is not merged
into or substituted for any existing chapter, reference, result, or appendix.
The public filtered thesis PDF is also unchanged; only this approved supplement
is synchronized to the public release. The printed Bash command uses backslash
continuations; the command above is the equivalent single-line command.
