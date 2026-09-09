@math
Feature: Adding

  Background:
    Given a fresh calculator

  Scenario: two numbers
    When I add 40
    And I add 2
    Then the total is 42

  @slow
  Scenario Outline: many
    When I add <n>
    Then the total is <n>

    Examples:
      | n |
      | 7 |
      | 9 |
