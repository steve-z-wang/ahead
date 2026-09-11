# Documentation maintenance

The first version maintains one English edition of the README, SDK guides, architecture notes and documentation website. Keep API identifiers and examples consistent with the implementation. Additional languages can be considered when there is a clear need and a maintenance plan.

## Updating documentation

- Update affected guides and examples in the same PR as a behavior change.
- Preserve working commands, relative links, code examples and explicit platform limitations.
- Use the accepted [concept names](architecture/concepts-and-naming.md): Model, Record, Identity, Mutation, Handler, Loader, Channel, Publish, Client, Persistence, Push/Pull, Cursor and Checkpoint.
- Historical designs and plans retain their original status and proposed APIs. Consult the [README](../README.md), package guides and [implementation evidence](implementation-progress.md) for delivered behavior.
- Check local links, heading fragments and Markdown formatting when moving or renaming pages.

## Documentation website

The website is maintained in a separate change from the English documentation conversion. It uses repository Markdown as its source, with an English quick start, concept explanations, client/backend guides, examples and search. Avoid independently maintained copies in GitHub Wiki. Website deployment and repository visibility are separate settings.
