# Writing architecture documentation

- Follow the component tree in the [architecture overview](../engineering/architecture.md).
- Give each leaf component its own Markdown file. Directory READMEs contain only links and brief descriptions.
- Start with responsibility and boundaries. Add interfaces and design decisions, with short reasons, when they are established.
- Link to the current code. Distinguish agreed target boundaries from the current implementation.
- Keep details in the owning component's document; link to related components instead of repeating them.
- Keep it minimal. Do not invent decisions or add empty sections to fill a template.
