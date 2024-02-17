# Lamp Bible (iOS)

A Bible reading companion app.

## Build

Add `v1.realm` to `./Lamp Bible`, build in Xcode.

### Updating Bundled Realm Database

1. Update realm database by copying DataModel changes to Lamp_Realm_Create project, making any updates to seed data JSON files, and running the project to create the `{version}.realm` file (see [`Lamp_Realm_Create/README.md`](https://github.com/mattsbennett/lamp-realm-create) for more details on this process).
2. Copy the updated `{version}.realm` file `./Lamp Bible`.
3. Add migration code to `./Lamp Bible/RealmManager.swift`.
    - When adding new properties to existing models, or adding new objects, simply increment the schema version - Realm will handle the rest.
    - Other changes will require also migration block to be added to `./Lamp Bible/RealmManager.swift`.
    - For changes to the bundled realm (via changes to the seed data), migration code (not via schema migration block) is also required to copy the user object data to the new realm, and to delete the old realm.
        - This is slightly onerous as there is no deep copy method for realm objects, so nested objects must be copied manually via iteration.
4. Once the migration code is added and the migration fully tested, the previous realm file can be deleted from the project, and only the new realm file shipped (the previous version was copied to existing user's devices already, so we don't need to ship it anymore).

## License

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)
