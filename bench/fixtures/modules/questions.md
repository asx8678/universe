# Questions about this codebase

Answer each question with a single integer, found in the code under `lib/`.
Write `answers.md` with exactly one line per question, in this form:

    Q1: 12

1. How many services can be live at once before a new one is refused?
2. At most how many directives can one tick contain?
3. When a worker is killed, how many milliseconds does the launcher wait after SIGTERM before SIGKILL?
4. A crashing service is restarted at most how many times within its restart window before it is reported failed?
5. How long is that restart window, in seconds?
6. What is the maximum size of one stored handle value, in MB?
7. After how many days are the run directories of settled workers deleted?
8. What is a service's default idle time-to-live, in seconds?
9. What is the maximum size of a directive's code, in KB?
10. By default, how many run workers may be running at the same time?
