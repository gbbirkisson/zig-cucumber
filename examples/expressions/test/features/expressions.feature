Feature: Expressions

  Scenario: Every capture kind binds
    Given the int 42
    And the float 1.5
    And the word hello
    And the string "a b"
    And the anonymous 7
    Then I have 5 bindings

  Scenario: Optional and alternation
    Given I press ok
    Given I press cancel
    When I add 1 item
    Then I have 3 bindings

  Scenario: A custom enum type
    Given the color blue
    Then the color was blue
    But the color was not red

  Scenario: Typed struct rows
    Given these people
      | name  | age |
      | Alice | 30  |
      | Bob   | 41  |
    Then the oldest is "Bob"

  Scenario: Escaped delimiters are literal text
    Given a literal (paren) and {brace} and a/slash
    Then I have 1 bindings
