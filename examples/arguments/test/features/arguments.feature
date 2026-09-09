Feature: Step arguments

  Scenario: A data table read cell by cell
    Given the table
      | name  | age | note          |
      | Alice | 30  | a\\b "quoted" |
      | Bob   | 41  | plain         |
    Then cell 0 "name" is "Alice"
    And cell 1 "age" is "41"
    And the "name" column is "Alice,Bob"
    And the note cell keeps its escapes

  Scenario: The same table as typed rows
    Given these people
      | name  | age |
      | Alice | 30  |
      | Bob   | 41  |
      | Cara  | 25  |
    Then the oldest is "Bob" aged 41

  Scenario: A doc string
    Given the payload
      """
      line one
      line two
      """
    Then the payload has 2 lines
    And the payload media type is unset

  Scenario: A doc string with a media type
    Given the payload
      """json
      {"a": 1}
      """
    Then the payload media type is "json"
