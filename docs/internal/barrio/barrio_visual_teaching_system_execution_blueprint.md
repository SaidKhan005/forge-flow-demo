# Barrio App - Visual & Teaching System (Execution Blueprint)

## Status

This document is an internal Barrio source-of-truth blueprint for future native app fulfillment.

It defines the intended visual atmosphere, motion language, teaching model, and controlled gamification direction for future Barrio screens and flows.

This is not a PDF-viewer requirement and not a direct UI build checklist. Later phases should translate this guidance into native product behavior.

Visual inspiration assets placed under `assets/internal/barrio/` should be treated as supporting reference material for mood, composition, color, and material feel during future Barrio implementation.

## Core Intent

You are not building UI. You are building an atmosphere that teaches through interaction.

The experience must feel like:

- growth (learning)
- flow (movement + ease)
- control (decision-making clarity)

If it looks good but does not improve decisions, it failed.

## Living System Interface

### Core UI Concept

Floating bubbles act as system nodes.

Each bubble represents a system:

- Forge & Flow: core engine; largest, central, pulsing
- Handbook: growth and training
- Jim Taylor Model: structure and discipline
- Interview Playbook: people and leadership

### Non-Negotiable Rules

- size = importance
- motion = activity
- glow = relevance

### Behavior

- idle: gentle floating
- active issue: Forge & Flow pulses
- learning focus: Handbook softly glows
- tap: expands into full screen with smooth scale, not a pop

## Atmospheric Layer

### Falling Leaves System

Leaves are background-only ambient motion.

Purpose:

- growth
- time
- learning progression

Implementation rules:

- extremely subtle and barely noticeable
- slow downward drift
- low opacity
- only on the Home screen

### Advanced Progression Signal

Leaves should reflect user progression:

- new user: more leaves to suggest early-learning chaos
- experienced user: fewer leaves to suggest clarity and control

This is feedback without words, not decoration.

## Motion System

### Strict Rules

Motion should feel futuristic only when it is:

- slow
- intentional
- reactive

It must respond to user action or system state.

### Interaction Examples

- tap bubble: smooth expand using scale plus fade
- swipe: subtle system shift with depth illusion
- alert: soft pulse with no flashing

### Hard Rule

If motion does not:

- guide attention
- reinforce hierarchy
- support decision-making

remove it.

## Color, Depth, and Material

### Base Palette

- light teal as the primary brand color
- soft neutrals such as cream and off-white

### Effects

- light glassmorphism with only subtle blur
- soft shadows for depth without heaviness
- layered foreground/background separation

### Avoid

- neon colors
- high-contrast gradients
- over-saturation

These break the hospitality feel, trust, and usability.

## Teaching System

### Core Philosophy

Learning should feel like interaction, not reading.

### Learning Loop

Every learning moment should move through:

1. situation
2. decision
3. outcome
4. explanation
5. action

Example:

"Friday dinner. CPLH drops to 3.2. What do you do?"

The user chooses, sees the result, and learns the consequence.

### Why It Works

- builds judgment instead of memory
- mimics real pressure
- reinforces Forge & Flow usage

## Interaction Style for Learning

### Card-Based Microlearning

Structure:

- one concept per card
- swipe to progress
- tap to expand deeper

Rules:

- 30-90 seconds per concept
- no scrolling walls of text
- always interactive

## Gamification Layer

### Purpose

Drive engagement without becoming childish.

### Elements

- progress tracking
- completion indicators
- scoreboards in a later phase
- badges only when tied to real performance

### Hard Rule

If gamification:

- does not improve behavior
- feels fake

remove it.

## Home Screen Composition

### Layout

Top:

- warm greeting
- current status such as "All systems running well" or an alert

Center:

- dominant Forge & Flow bubble

Surrounding:

- three to four secondary bubbles

Background:

- subtle falling leaves

### Behavior Logic

- operational issue: Forge & Flow highlights
- learning opportunity: Handbook highlights
- no issues: calm state

## Common Failure Points

1. Everything moves, creating chaos and cognitive overload.
2. Animation comes before structure, so it looks good but works poorly.
3. There is no hierarchy, so the user does not know where to go.

## Final System Principle

Every visual element must help the user decide faster.

Reality check:

- if the UI looks cool but slows action, it fails
- if it adds motion without meaning, it fails
- if it feels like a library, it fails

If it:

- guides attention
- teaches through decisions
- connects learning to real operations

then the system is working.

## Final One-Line Vision

A living, interactive system where restaurant staff learn through decisions, visualize growth, and operate with clarity under pressure.
