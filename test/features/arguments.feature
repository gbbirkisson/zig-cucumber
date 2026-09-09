Feature: Step arguments

  Scenario: a data table
    Given the rows
      | name  | age | note          |
      | Alice | 30  | a\\b "quoted" |

  Scenario: a doc string
    Given the payload
      """json
      {"a": 1}
      """
