@counter
Feature: Counting

  Background:
    Given a fresh counter

  Scenario: adding twice
    When I add 40
    And I add 2
    Then the count is 42

  Scenario Outline: adding once
    When I add <n>
    Then the count is <n>

    Examples:
      | n |
      | 7 |
      | 9 |
