# Writing architecture documentation

Use the [arc42 template](https://arc42.org/overview/). Its [minimum guidance](https://faq.arc42.org/questions/B-4/) recommends covering core quality requirements, context and interfaces, solution strategy and important decisions, top-level building blocks, and key crosscutting concepts across the system documentation.

## Style

Use short bullets. Omit unused optional sections. Verify claims against code and distinguish current implementation from target design. Link to shared explanations instead of repeating them.

## Sections

Select sections for the system or component being documented. arc42 [does not prescribe a universal required/optional checklist](https://faq.arc42.org/questions/B-1/). Component documents cover only their own scope; inherited context can be linked.

1. **Introduction and Goals.** Purpose, responsibilities and intended outcomes.
2. **Architecture Constraints.** External requirements that restrict the design.
3. **Context and Scope.** Boundaries, dependencies and external interfaces: operations, inputs and outputs.
4. **Solution Strategy.** The overall approach to meeting the goals.
5. **Building Block View.** Internal components and responsibilities, with code links. For a leaf, identify its implementation without inventing further subdivisions.
6. **Runtime View.** Interactions, state transitions, ordering and recovery.
7. **Deployment View.** Process, device and infrastructure placement.
8. **Crosscutting Concepts.** Mechanisms shared across components; link to their owning document.
9. **Architecture Decisions.** Significant choices, alternatives and consequences.
10. **Quality Requirements.** Correctness invariants and other verifiable quality requirements; link to guarantees or tests where available.
11. **Risks and Technical Debt.** Known risks, limitations and implementation gaps, with relevant issue links.
12. **Glossary.** Terms that need clarification; reuse shared definitions.

## Optional sections

Ahead uses these conventions:

- Omit sections that do not apply; do not leave empty headings.
- Keep the original arc42 numbers in headings, such as `## 3. Context and Scope`. Do not renumber after omissions.
- If a relevant section is unresolved, keep its heading and briefly state what needs clarification.

## Organization

Follow the [component tree](../engineering/architecture.md). One file per leaf; READMEs contain links and brief descriptions.
