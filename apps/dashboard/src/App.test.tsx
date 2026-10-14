import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { App } from './App';

describe('<App />', () => {
  it('renders the AIJ Closer shell', () => {
    render(<App />);

    expect(screen.getByRole('heading', { name: /aij closer/i })).toBeDefined();
    expect(screen.getByText(/owner dashboard scaffold/i)).toBeDefined();
  });
});
