## Engineering practices

These are the standards this pipeline holds itself to. They are inlined here
because you need them: do not go looking for a skill or a reference file to find
out how well the work must be done.

### General

- Match existing architecture and naming before introducing abstractions.
- Keep the diff focused on the approved OpenSpec change.
- Prefer explicit domain behavior, clear errors, and small cohesive functions.
- Preserve backward compatibility unless the proposal explicitly changes it.
- Never include secrets, local environment files, build output, or unrelated
  cleanup.
- Treat migrations, money, permissions, multi-tenancy, and public contracts as
  high-risk.

### Python and Django

- Keep Django Ninja views thin; put business rules in the established service
  layer.
- Use the repository's Pydantic/Django Ninja schema patterns and strict typing.
- Scope club data correctly and enforce authorization on the backend.
- Use transactions where a partial write would violate an invariant.
- Generate migrations only for intentional model changes; inspect their
  operations.
- Follow Ruff, Pyright, Django, and local test conventions.

### TypeScript and Angular

- Use standalone Angular components and existing signal-based state services.
- Use the established Axios service layer and interceptors.
- Keep frontend models camelCase and backend payloads snake_case; rely on the
  existing conversion.
- Preserve `Club-ID` injection and central error handling.
- Use existing PrimeNG and Tailwind patterns; do not introduce a new UI system.
- Keep components focused; move reusable state and API behavior to established
  services.

### Cross-stack contracts

- Align request, response, validation, nullability, enum, date/time, and error
  semantics.
- Remember monetary values are kVND.
- Update both sides and their tests when an API contract changes.
- Avoid UI-only permission controls as a security boundary.

### Repository instructions win

The target repository's own `CLAUDE.md`, `AGENTS.md`, Feature RFC guidance and
OpenSpec skills override anything above. Where this list and a repository-local
instruction disagree, follow the repository.
