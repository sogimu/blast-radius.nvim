(import_statement
  name: [(dotted_name) @import_name
         (aliased_import name: (dotted_name) @import_name)])

(import_from_statement
  module_name: (relative_import
    (dotted_name) @import_from_name)?)
