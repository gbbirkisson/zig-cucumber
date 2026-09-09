@feature
Feature: Structure

  Background:
    Given a feature background step

  Scenario: Outside any rule
    Then the trace is "feature"

  @rule
  Rule: A rule groups scenarios

    Background:
      Given a rule background step

    @scenario
    Scenario: Inside the rule
      Then the trace is "in-rule,feature,rule"

    @outline
    Scenario Outline: Outlined inside the rule
      Then the trace is "in-rule,feature,rule" and the row is "<what>"

      @examples
      Examples:
        | what |
        | one  |
        | two  |
